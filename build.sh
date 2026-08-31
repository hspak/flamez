#!/usr/bin/env bash
set -euo pipefail

prefix="${FLAMEZ_PREFIX:-/usr/local}"
binary="${prefix}/bin/flamez"
bpf_dir="${prefix}/share/flamez"
bpf_object="${bpf_dir}/flamez.bpf.o"

if ! command -v findmnt >/dev/null 2>&1; then
    echo "ERROR: findmnt is required to verify file-capability mount semantics." >&2
    exit 1
fi

~/zig/zig build --release=safe -Dfps-counter=true -Dmsaa=false "$@"

# Install the loader and its compiled BPF object together. The executable
# derives this share path from /proc/self/exe, so it works from any cwd.
sudo install -d -o root -g root -m 0755 "${prefix}/bin" "${bpf_dir}"

mount_options="$(findmnt -no OPTIONS --target "${prefix}/bin")"
if [[ ",${mount_options}," == *,nosuid,* ]]; then
    echo >&2
    echo "ERROR: ${prefix}/bin is on a nosuid mount." >&2
    echo "Linux will ignore file capabilities on this filesystem." >&2
    echo "Install to a filesystem without nosuid or use a privileged collector service." >&2
    exit 1
fi

sudo install -o root -g root -m 0755 zig-out/bin/flamez "${binary}"
sudo install -o root -g root -m 0644 \
    zig-out/share/flamez/flamez.bpf.o "${bpf_object}"

# install(1) replaces the destination inode, which clears file capabilities;
# always apply them after copying the freshly built executable.
#
# cap_bpf + cap_perfmon load and attach raw-tracepoint BPF programs.
sudo setcap 'cap_bpf,cap_perfmon=ep' "${binary}"

installed_caps="$(getcap "${binary}")"
if [[ "${installed_caps}" != "${binary} cap_perfmon,cap_bpf=ep" ]]; then
    echo "ERROR: unexpected file capabilities: ${installed_caps:-none}" >&2
    exit 1
fi

echo "Installed Flamez:"
ls -l "${binary}" "${bpf_object}"
getcap "${binary}"
echo
echo "Run the installed capable binary (not ./zig-out/bin/flamez):"
echo "  ${binary} <target> [target args...]"
