#!/usr/bin/env python3
"""Read macOS process counters; CPU times use the host Mach timebase."""
import argparse, ctypes, json, re, subprocess, time
from pathlib import Path
parser = argparse.ArgumentParser()
parser.add_argument('--seconds', type=int, default=30)
parser.add_argument('--output')
args = parser.parse_args()
sdk = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
header = (Path(sdk) / 'usr/include/sys/resource.h').read_text()
body = re.search(r'struct rusage_info_v4 \{(.*?)\};', header, re.S).group(1)
class Usage(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in re.findall(r'uint64_t\s+(\w+);', body)]
class Timebase(ctypes.Structure):
    _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]
lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
tb = Timebase(); ctypes.CDLL('/usr/lib/libSystem.B.dylib').mach_timebase_info(ctypes.byref(tb))
factor = tb.numer / tb.denom / 1e9
processes = []
for line in subprocess.check_output(['ps', '-axo', 'pid=,command='], text=True).splitlines():
    pid, _, command = line.strip().partition(' ')
    if '/MenuCraft.app/Contents/' in command and not command.startswith(('/bin/', 'python')):
        processes.append((int(pid), command))
def read(pid):
    value = Usage()
    if lib.proc_pid_rusage(pid, 4, ctypes.byref(value)): raise OSError(ctypes.get_errno())
    return {name: getattr(value, name) for name, _ in Usage._fields_ if name != 'uuid'}
start = time.monotonic(); first = {pid: read(pid) for pid, _ in processes}
last = {pid: dict(value) for pid, value in first.items()}; previous = start; samples = {pid: [] for pid, _ in processes}
for index in range(args.seconds):
    time.sleep(max(0, start + index + 1 - time.monotonic()))
    current = time.monotonic()
    for pid, _ in processes:
        value = read(pid); a = last[pid]
        cpu = (value['ri_user_time'] + value['ri_system_time'] - a['ri_user_time'] - a['ri_system_time']) * factor / (current - previous) * 100
        samples[pid].append({'cpu_percent': cpu, 'memory_MiB': value['ri_phys_footprint'] / 2**20})
        last[pid] = value
    previous = current
elapsed = previous - start; result = {'seconds': elapsed, 'processes': []}
for pid, command in processes:
    a, b = first[pid], last[pid]
    result['processes'].append({'pid': pid, 'command': command, 'cpu_percent': (b['ri_user_time'] + b['ri_system_time'] - a['ri_user_time'] - a['ri_system_time']) * factor / elapsed * 100,
        'peak_cpu_percent': max(x['cpu_percent'] for x in samples[pid]), 'memory_MiB': b['ri_phys_footprint'] / 2**20,
        'memory_start_MiB': a['ri_phys_footprint'] / 2**20, 'memory_peak_MiB': max(x['memory_MiB'] for x in samples[pid]),
        'idle_wakeups': b['ri_pkg_idle_wkups'] - a['ri_pkg_idle_wkups'], 'interrupt_wakeups': b['ri_interrupt_wkups'] - a['ri_interrupt_wkups'],
        'disk_read_bytes': b['ri_diskio_bytesread'] - a['ri_diskio_bytesread'], 'disk_written_bytes': b['ri_diskio_byteswritten'] - a['ri_diskio_byteswritten']})
text = json.dumps(result, ensure_ascii=False, indent=2)
if args.output: Path(args.output).write_text(text + '\n')
print(text)
