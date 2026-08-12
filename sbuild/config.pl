# Project-owned sbuild configuration for native ARM64 Debian package builds.
# Build commands must point SBUILD_CONFIG at this file.

my $cache_root = "$ENV{HOME}/.cache/cix-neo-sbuild";
my $ccache_dir = "$cache_root/ccache";
my $apt_archives_dir = "$cache_root/apt-archives";

# Keep APT's working archive private to each disposable chroot. The persistent
# cache is mounted separately, so sbuild's identically named build-dependency
# dummy packages cannot leak between builds. Only real downloaded archives are
# copied in and out of the persistent cache.
my $restore_apt_archives =
    q{find /mnt -maxdepth 1 -type f -name '*.deb' ! -name 'sbuild-build-depends-*.deb' -exec cp --no-clobber --target-directory=/var/cache/apt/archives {} +};
my $save_apt_archives =
    q{find /var/cache/apt/archives -maxdepth 1 -type f -name '*.deb' ! -name 'sbuild-build-depends-*.deb' -exec cp --no-clobber --target-directory=/mnt {} +};

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
$external_commands = {
    'chroot-setup-commands' => [$restore_apt_archives],
    'starting-build-commands' => [$save_apt_archives],
    'build-deps-failed-commands' => [$save_apt_archives],
    'chroot-cleanup-commands' => [$save_apt_archives],
};
$unshare_bind_mounts = [
    {
        directory => $ccache_dir,
        mountpoint => '/build/ccache',
    },
    {
        directory => $apt_archives_dir,
        mountpoint => '/mnt',
    },
];

1;
