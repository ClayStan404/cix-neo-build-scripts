# Project-owned sbuild configuration for native ARM64 Debian package builds.
# Build commands must point SBUILD_CONFIG at this file.

my $cache_root = "$ENV{HOME}/.cache/cix-neo-sbuild";
my $ccache_dir = "$cache_root/ccache";
my $apt_archives_dir = "$cache_root/apt-archives";

$build_source = 1;
$lintian_require_success = 1;
$apt_clean = 0;
$apt_keep_downloaded_packages = 1;

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
};
$unshare_bind_mounts = [
    {
        directory => $ccache_dir,
        mountpoint => '/build/ccache',
    },
    {
        directory => $apt_archives_dir,
        mountpoint => '/var/cache/apt/archives',
    },
];

1;
