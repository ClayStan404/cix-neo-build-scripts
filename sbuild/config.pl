# Project-owned sbuild configuration for native ARM64 Debian package builds.
# Build commands must point SBUILD_CONFIG at this file.

my $multiarch = `dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null`;
chomp $multiarch;
die "sbuild config: cannot determine DEB_HOST_MULTIARCH\n" unless $multiarch;

my $ccache_dir = "$ENV{HOME}/.cache/cix-neo-sbuild/ccache";

$build_source = 1;

# Kernel builds can exceed the capacity of a tmpfs-backed /tmp.
my $tmpdir_root = $ENV{CIX_SBUILD_TMPDIR_ROOT} // '/var/tmp/cix-neo-sbuild';
$unshare_tmpdir_template = "$tmpdir_root/tmp.sbuild.XXXXXXXXXX";

$path = join(':',
    '/usr/lib/ccache',
    '/usr/local/sbin',
    '/usr/local/bin',
    '/usr/sbin',
    '/usr/bin',
    '/sbin',
    '/bin');
$build_environment = {
    'CCACHE_DIR' => '/build/ccache',
    'CCACHE_UMASK' => '000',
    'LD_PRELOAD' => "/usr/lib/${multiarch}/libeatmydata.so",
};
$unshare_bind_mounts = [
    {
        directory => $ccache_dir,
        mountpoint => '/build/ccache',
    },
];

1;
