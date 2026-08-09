# Project-owned sbuild configuration for native ARM64 Debian package builds.
# Build commands must point SBUILD_CONFIG at this file.

use Dpkg::BuildInfo;

my $multiarch = `dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null`;
chomp $multiarch;
die "sbuild config: cannot determine DEB_HOST_MULTIARCH\n" unless $multiarch;

my $use_ccache = ($ENV{CIX_SBUILD_USE_CCACHE} // '1') ne '0';
my $use_eatmydata = ($ENV{CIX_SBUILD_USE_EATMYDATA} // '1') ne '0';
my $cache_home = $ENV{XDG_CACHE_HOME} // "$ENV{HOME}/.cache";
my $ccache_dir = $ENV{CIX_SBUILD_CCACHE_DIR}
    // "${cache_home}/cix-neo-sbuild/ccache";

$chroot_mode = 'unshare';
$distribution = $ENV{CIX_SBUILD_DISTRIBUTION} // 'trixie';
$chroot = $ENV{CIX_SBUILD_CHROOT} if $ENV{CIX_SBUILD_CHROOT};

$build_arch_all = 1;
$build_arch_any = 1;
$build_source = 1;
$source_only_changes = 0;

$run_lintian = 1;
$lintian_opts = ['-I'];
$run_autopkgtest = 0;
$run_piuparts = 0;

# Kernel builds can exceed the capacity of a tmpfs-backed /tmp.
$unshare_tmpdir_template = $ENV{CIX_SBUILD_TMPDIR_TEMPLATE}
    // '/var/tmp/cix-neo-sbuild/tmp.sbuild.XXXXXXXXXX';

my %build_environment;

if ($use_eatmydata) {
    $build_environment{'LD_PRELOAD'} =
        "/usr/lib/${multiarch}/libeatmydata.so";
}

if ($use_ccache) {
    $path = join(':',
        '/usr/lib/ccache',
        '/usr/local/sbin',
        '/usr/local/bin',
        '/usr/sbin',
        '/usr/bin',
        '/sbin',
        '/bin');
    $build_path = '/build/package/';
    $dsc_dir = 'package';
    $build_environment{'CCACHE_DIR'} = '/build/ccache';
    $build_environment{'CCACHE_UMASK'} = '000';
    $unshare_bind_mounts = [
        {
            directory => $ccache_dir,
            mountpoint => '/build/ccache',
        },
    ];
}

$build_environment = \%build_environment;
$environment_filter = [
    (map { "^\Q$_\E\$" } Dpkg::BuildInfo::get_build_env_allowed()),
];

$build_dir = $ENV{CIX_SBUILD_OUTPUT_DIR}
    if $ENV{CIX_SBUILD_OUTPUT_DIR};

1;
