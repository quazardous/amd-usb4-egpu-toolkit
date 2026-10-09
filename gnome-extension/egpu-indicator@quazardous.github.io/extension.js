// eGPU Indicator — status, usage and safe eject for an NVIDIA eGPU on a
// USB4 / Thunderbolt laptop. Companion of amd-usb4-egpu-toolkit.
//
// Safety rules, inherited from the toolkit:
//   - the panel icon only reads sysfs, ps, systemctl and the journal; it never
//     touches the NVIDIA driver;
//   - nvidia-smi runs only while the menu is open, only if the driver is bound,
//     no nvidia process is stuck in D state, the link is not in the Phoenix
//     x1-Gen1 state, and no previous call is still running. A call that times
//     out marks the driver as not responding and stops further calls until the
//     GPU leaves the bus (piling up calls on a stuck driver is the NVRM cascade);
//   - eject goes through pkexec on a root-owned copy of egpu-eject.sh, which
//     refuses to act while a program uses the GPU.

import GObject from 'gi://GObject';
import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import St from 'gi://St';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

Gio._promisify(Gio.Subprocess.prototype, 'communicate_utf8_async');

// Installed by scripts/setup-compute.sh (root-owned, not user-writable).
const EJECT_HELPER = '/usr/local/lib/amd-usb4-egpu-toolkit/egpu-eject.sh';
const POLL_OPEN_S = 3;
const POLL_CLOSED_S = 10;
const XID_CHECK_S = 30;
const SMI_TIMEOUT_S = 5;

const decoder = new TextDecoder();

function readFile(path) {
    try {
        const [ok, bytes] = GLib.file_get_contents(path);
        return ok ? decoder.decode(bytes).trim() : null;
    } catch {
        return null;
    }
}

function listDir(path) {
    const names = [];
    try {
        const en = Gio.File.new_for_path(path).enumerate_children(
            'standard::name', Gio.FileQueryInfoFlags.NONE, null);
        let info;
        while ((info = en.next_file(null)) !== null)
            names.push(info.get_name());
        en.close(null);
    } catch {
        // directory absent (no thunderbolt bus, ...)
    }
    return names;
}

async function run(argv, timeoutS = 0) {
    const full = timeoutS ? ['timeout', String(timeoutS), ...argv] : argv;
    try {
        const proc = Gio.Subprocess.new(full,
            Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE);
        const [stdout, stderr] = await proc.communicate_utf8_async(null, null);
        return {
            ok: proc.get_successful(),
            status: proc.get_if_exited() ? proc.get_exit_status() : -1,
            stdout: stdout ?? '',
            stderr: stderr ?? '',
        };
    } catch (e) {
        return {ok: false, status: -1, stdout: '', stderr: String(e)};
    }
}

// First NVIDIA VGA / 3D controller on the PCI bus, from sysfs only.
function findGpu() {
    for (const addr of listDir('/sys/bus/pci/devices')) {
        const base = `/sys/bus/pci/devices/${addr}`;
        if (readFile(`${base}/vendor`) !== '0x10de')
            continue;
        const cls = readFile(`${base}/class`) ?? '';
        if (!cls.startsWith('0x0300') && !cls.startsWith('0x0302'))
            continue;
        let driver = null;
        try {
            driver = GLib.path_get_basename(GLib.file_read_link(`${base}/driver`));
        } catch {
            // no driver bound
        }
        return {
            addr,
            driver,
            speed: readFile(`${base}/current_link_speed`),
            width: readFile(`${base}/current_link_width`),
        };
    }
    return null;
}

// Thunderbolt / USB4 peripherals (not host routers, not retimers).
function tbPeripherals() {
    const out = [];
    for (const name of listDir('/sys/bus/thunderbolt/devices')) {
        if (!/^\d+-[1-9]\d*$/.test(name))
            continue;
        const base = `/sys/bus/thunderbolt/devices/${name}`;
        const label = `${readFile(`${base}/vendor_name`) ?? ''} ${readFile(`${base}/device_name`) ?? ''}`.trim();
        out.push({name, label: label || name, authorized: readFile(`${base}/authorized`) === '1'});
    }
    return out;
}

// Programs holding /dev/nvidia* open. Only the user's own processes are
// readable without root, which covers desktop apps (a GTK4 app probing Vulkan
// / EGL holds the GPU and blocks a clean eject). Root daemons are not seen,
// nvidia-persistenced included, which egpu-eject.sh handles anyway. Walking
// /proc happens in a subprocess to keep the shell's main loop responsive.
async function nvidiaHolders() {
    const r = await run(['find', '/proc', '-mindepth', '3', '-maxdepth', '3',
        '-path', '/proc/[0-9]*/fd/*', '-lname', '/dev/nvidia*']);
    const pids = new Set(r.stdout.split('\n').map(l => l.split('/')[2]).filter(Boolean));
    return [...pids].map(pid => readFile(`/proc/${pid}/comm`) ?? pid);
}

const GEN = {'2.5': 1, '5.0': 2, '8.0': 3, '16.0': 4, '32.0': 5, '64.0': 6};

// Same classification as egpu-diag.sh: the GPU's OWN link is the signal.
function linkInfo(gpu) {
    if (!gpu?.speed)
        return {text: 'unknown', bug: false};
    const gen = GEN[gpu.speed.split(' ')[0]];
    const text = `PCIe Gen${gen ?? '?'} x${gpu.width}`;
    if (gen === 1 && gpu.width === '1')
        return {text: `${text} — Phoenix x1-Gen1 bug, power-cycle and re-plug`, bug: true};
    if (gen === 1)
        return {text: `${text} (idle)`, bug: false};
    return {text, bug: false};
}

const EgpuIndicator = GObject.registerClass(
class EgpuIndicator extends PanelMenu.Button {
    _init(path) {
        super._init(0.0, 'eGPU Indicator');

        // Graphics-card icon shipped with the extension (symbolic: recoloured
        // like the other panel icons). The eGPU does compute, not display.
        this._gpuIcon = Gio.icon_new_for_string(`${path}/icons/egpu-symbolic.svg`);
        this._icon = new St.Icon({
            gicon: this._gpuIcon,
            style_class: 'system-status-icon',
        });
        this.add_child(this._icon);

        const detail = text => {
            const item = new PopupMenu.PopupMenuItem(text, {reactive: false});
            item.label.add_style_class_name('egpu-indicator-detail');
            this.menu.addMenuItem(item);
            return item;
        };
        this._title = new PopupMenu.PopupMenuItem('eGPU', {reactive: false});
        this.menu.addMenuItem(this._title);
        this._status = detail('');
        this._link = detail('');
        this._temp = detail('');
        this._load = detail('');
        this._vram = detail('');
        this._power = detail('');
        this._persist = detail('');
        this._apps = detail('');

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this._ejectItem = new PopupMenu.PopupImageMenuItem('Eject eGPU', 'media-eject-symbolic');
        this._ejectItem.connect('activate', () => this._eject());
        this.menu.addMenuItem(this._ejectItem);
        this._undoItem = new PopupMenu.PopupImageMenuItem('Undo eject', 'view-refresh-symbolic');
        this._undoItem.connect('activate', () => this._undo());
        this.menu.addMenuItem(this._undoItem);

        this._state = {};
        this._ejected = false;
        this._busy = false;
        this._smiInFlight = false;
        this._smiHung = false;
        this._lastXidCheck = 0;
        this._xid = false;
        this._refreshing = false;
        this._destroyed = false;

        this.menu.connectObject('open-state-changed', (_m, open) => {
            if (open)
                this._refresh();
            this._schedule();
        }, this);

        this._refresh();
        this._schedule();
    }

    _schedule() {
        if (this._timer)
            GLib.source_remove(this._timer);
        const secs = this.menu.isOpen ? POLL_OPEN_S : POLL_CLOSED_S;
        this._timer = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, secs, () => {
            this._refresh();
            return GLib.SOURCE_CONTINUE;
        });
    }

    async _refresh() {
        if (this._refreshing || this._destroyed)
            return;
        this._refreshing = true;
        try {
            await this._collect();
            if (!this._destroyed)
                this._render();
        } catch (e) {
            console.error(`eGPU Indicator: ${e}`);
        } finally {
            this._refreshing = false;
        }
    }

    async _collect() {
        const gpu = findGpu();
        const tb = tbPeripherals();
        const s = {gpu, tb, link: linkInfo(gpu)};

        // GPU back on the bus, or enclosure gone: forget the ejected state.
        if (gpu || !tb.some(d => !d.authorized))
            this._ejected = this._ejected && !gpu && tb.length > 0;
        if (!gpu)
            this._smiHung = false;

        const ps = await run(['ps', '-eo', 'stat=,comm=']);
        s.stuck = ps.stdout.split('\n')
            .filter(l => /^D/.test(l.trim()) && /nvidia/.test(l)).length;

        if (gpu?.driver === 'nvidia') {
            const r = await run(['systemctl', 'is-active', 'nvidia-persistenced.service']);
            s.persist = r.stdout.trim() || 'unknown';
        }

        const now = GLib.get_monotonic_time() / 1e6;
        if (gpu && now - this._lastXidCheck > XID_CHECK_S) {
            this._lastXidCheck = now;
            const j = await run(['journalctl', '-k', '-q', '-o', 'cat',
                '--since=-10min', '-g', 'NVRM: Xid|fallen off the bus']);
            this._xid = j.stdout.trim().length > 0;
        }
        s.xid = gpu ? this._xid : false;

        // Driver queries: menu open only, and only when it is safe.
        const smiSafe = gpu?.driver === 'nvidia' && s.stuck === 0 && !s.link.bug &&
            !this._smiHung && !this._smiInFlight &&
            GLib.file_test('/dev/nvidia0', GLib.FileTest.EXISTS);
        if (this.menu.isOpen && smiSafe) {
            this._smiInFlight = true;
            try {
                const q = await run(['nvidia-smi',
                    '--query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total,power.draw',
                    '--format=csv,noheader,nounits'], SMI_TIMEOUT_S);
                if (q.status === 124) {
                    this._smiHung = true;
                } else if (q.ok) {
                    const [name, temp, util, used, total, power] =
                        q.stdout.trim().split('\n')[0].split(',').map(x => x.trim());
                    s.smi = {name, temp, util, used, total, power};
                    const a = await run(['nvidia-smi',
                        '--query-compute-apps=pid,process_name,used_memory',
                        '--format=csv,noheader,nounits'], SMI_TIMEOUT_S);
                    if (a.status === 124)
                        this._smiHung = true;
                    else if (a.ok)
                        s.apps = a.stdout.trim().split('\n').filter(l => l.trim())
                            .map(l => l.split(',')[1]?.trim()).filter(Boolean);
                }
            } finally {
                this._smiInFlight = false;
            }
        }
        s.smiHung = this._smiHung;
        s.holders = gpu && this.menu.isOpen ? await nvidiaHolders() : [];
        this._state = s;
    }

    _render() {
        const s = this._state;
        const enclosure = s.tb?.find(d => d.authorized) ?? s.tb?.[0];

        let mode;
        if (this._busy)
            mode = 'busy';
        else if (!s.gpu && this._ejected)
            mode = 'ejected';
        else if (!s.gpu)
            mode = 'absent';
        else if (s.stuck > 0 || s.link.bug || s.xid || s.smiHung ||
                 s.gpu.driver !== 'nvidia' || (s.persist && s.persist !== 'active'))
            mode = 'warn';
        else
            mode = 'ok';

        // Panel: only when an eGPU is there or was just ejected.
        const shown = mode !== 'absent';
        if (this.container)
            this.container.visible = shown;
        else
            this.visible = shown;

        this._icon.remove_style_class_name('egpu-indicator-warning');
        this._icon.remove_style_class_name('egpu-indicator-ejected');
        this._icon.remove_style_class_name('egpu-indicator-dim');
        const themed = {
            warn: 'dialog-warning-symbolic',
            ejected: 'media-eject-symbolic',
            busy: 'media-eject-symbolic',
        }[mode];
        this._icon.gicon = themed ? new Gio.ThemedIcon({name: themed}) : this._gpuIcon;
        if (mode === 'warn')
            this._icon.add_style_class_name('egpu-indicator-warning');
        if (mode === 'ejected')
            this._icon.add_style_class_name('egpu-indicator-ejected');
        if (mode === 'busy')
            this._icon.add_style_class_name('egpu-indicator-dim');

        const set = (item, text) => {
            item.visible = Boolean(text);
            if (text)
                item.label.text = text;
        };

        set(this._title, s.smi?.name ?? (s.gpu ? `NVIDIA GPU ${s.gpu.addr}` : 'eGPU'));
        const where = enclosure ? ` — ${enclosure.label}` : '';
        let status = {
            ok: `Connected${where}`,
            busy: 'Ejecting…',
            ejected: `Ejected — safe to unplug${where}`,
        }[mode] ?? '';
        if (mode === 'warn') {
            if (s.stuck > 0)
                status = `${s.stuck} nvidia process(es) stuck — run egpu-recover.sh, do not unplug`;
            else if (s.smiHung)
                status = 'Driver not responding — run egpu-recover.sh';
            else if (s.gpu.driver !== 'nvidia')
                status = `No NVIDIA driver bound (driver: ${s.gpu.driver ?? 'none'})`;
            else if (s.link.bug)
                status = 'Link trained at Gen1 x1 (Phoenix bug)';
            else if (s.xid)
                status = 'Xid reported in the last 10 min — see journalctl -k';
            else
                status = `nvidia-persistenced ${s.persist}`;
        }
        set(this._status, status);

        const live = s.gpu && mode !== 'busy';
        set(this._link, live ? `Link  ${s.link.text}` : '');
        set(this._temp, live && s.smi ? `Temperature  ${s.smi.temp} °C` : '');
        set(this._load, live && s.smi ? `Load  ${s.smi.util} %` : '');
        // nvidia-smi prints "[N/A]" for values a card does not report.
        const num = v => (Number.isFinite(Number(v)) ? Number(v) : null);
        const used = num(s.smi?.used), total = num(s.smi?.total), power = num(s.smi?.power);
        set(this._vram, live && used !== null && total !== null
            ? `VRAM  ${(used / 1024).toFixed(1)} / ${(total / 1024).toFixed(1)} GiB` : '');
        set(this._power, live && power !== null ? `Power  ${Math.round(power)} W` : '');
        set(this._persist, live && s.persist ? `Persistence daemon  ${s.persist}` : '');
        // CUDA processes (nvidia-smi) plus any program holding /dev/nvidia*:
        // the latter is what egpu-eject.sh refuses to eject under.
        if (live && this.menu.isOpen) {
            const users = new Set([...(s.apps ?? []), ...s.holders]);
            set(this._apps, users.size ? `In use by: ${[...users].join(', ')}` : 'In use by: nothing');
        } else if (!live) {
            set(this._apps, '');
        }

        this._ejectItem.visible = Boolean(s.gpu) && mode !== 'busy';
        this._ejectItem.setSensitive(s.stuck === 0);
        this._undoItem.visible = mode === 'ejected';
    }

    async _eject() {
        if (!GLib.file_test(EJECT_HELPER, GLib.FileTest.IS_EXECUTABLE)) {
            Main.notify('eGPU eject unavailable',
                `${EJECT_HELPER} is missing: run the toolkit's scripts/setup-compute.sh`);
            return;
        }
        this._busy = true;
        this._render();
        const r = await run(['pkexec', EJECT_HELPER, '--yes']);
        this._busy = false;
        if (r.ok) {
            this._ejected = true;
            Main.notify('eGPU ejected', 'Safe to unplug: pull the cable, then switch the enclosure off.');
        } else if (r.status === 126 || r.status === 127) {
            Main.notify('eGPU eject cancelled', 'Authentication was dismissed or refused.');
        } else {
            const msg = `${r.stdout}\n${r.stderr}`.split('\n')
                .map(l => l.trim()).filter(l => l).slice(-4).join('\n');
            Main.notify('eGPU not ejected', msg || `egpu-eject.sh exited with ${r.status}`);
        }
        this._refresh();
    }

    async _undo() {
        this._busy = true;
        this._render();
        const r = await run(['pkexec', EJECT_HELPER, '--undo']);
        this._busy = false;
        if (r.ok)
            this._ejected = false;
        else if (r.status !== 126 && r.status !== 127)
            Main.notify('eGPU undo failed', r.stdout.trim().split('\n').slice(-2).join('\n'));
        this._refresh();
    }

    destroy() {
        this._destroyed = true;
        if (this._timer) {
            GLib.source_remove(this._timer);
            this._timer = null;
        }
        super.destroy();
    }
});

export default class EgpuIndicatorExtension extends Extension {
    enable() {
        this._indicator = new EgpuIndicator(this.path);
        Main.panel.addToStatusArea(this.uuid, this._indicator);
    }

    disable() {
        this._indicator?.destroy();
        this._indicator = null;
    }
}
