# A debhelper build system class for handling CMake based projects.
# It prefers out of source tree building.
#
# Copyright: © 2020 Alastair McKinstry
# License: GPL-2+

# Based on cmake buildsystem module.
# TODO: Inherit more directly

package Debian::Debhelper::Buildsystem::ecbuild;

use strict;
use warnings;
use Debian::Debhelper::Dh_Lib qw(%dh compat dpkg_architecture_value error is_cross_compiling);
use parent qw(Debian::Debhelper::Buildsystem);

### TODO: Set these automatically
# Fixes for 32-bit archss
#ARCH_32BIT:=   i386 armel armhf mipsel hppa hurd-i386 m68k powerpc sh4 x32
#ENABLE_32BIT:= $(if $(filter $(DEB_TARGET_ARCH), $(ARCH_32BIT)),On,Off)

my $target_arch = dpkg_architecture_value('DEB_TARGET_ARCH');

# Strange bug with omp.h headers and clang-tidy on some archs
#ARCH_CLANG_TIDY_OFF:= s390x mipsel
#ENABLE_CLANG_TIDY:= $(if $(filter $(DEB_TARGET_ARCH), $(ARCH_CLANG_TIDY_OFF)),Off,On)

# TODO, from emos?
# DCMAKE_INSTALL_PREFIX=$(DESTDIR) 

my @STANDARD_CMAKE_FLAGS = qw(
  -DCMAKE_MODULE_PATH=/usr/share/ecbuild/cmake
  -DECBUILD_MACROS_DIR=/usr/share/ecbuild/cmake
  -DENABLE_BIT_REPRODUCIBLE=On
  -DCMAKE_INSTALL_PREFIX=/usr
  -DCMAKE_BUILD_TYPE=Release
  -DDISABLE_OS_CHECK=On 
  -DBUILD_SITE=debian
  -DCMAKE_INSTALL_LOCALSTATEDIR=/var
  -DCMAKE_EXPORT_NO_PACKAGE_REGISTRY=ON
  -DCMAKE_FIND_PACKAGE_NO_PACKAGE_REGISTRY=ON
);

my %DEB_HOST2CMAKE_SYSTEM = (
	'linux'    => 'Linux',
	'kfreebsd' => 'kFreeBSD',
	'hurd'     => 'GNU',
);

my %GNU_CPU2SYSTEM_PROCESSOR = (
	'arm'         => 'armv7l',
	'mips64el'    => 'mips64',
	'powerpc64le' => 'ppc64le',
);

my %TARGET_BUILD_SYSTEM2CMAKE_GENERATOR = (
	'makefile' => 'Unix Makefiles',
	'ninja'    => 'Ninja',
);

sub DESCRIPTION {
	"ECBuild (ECMWF CMakeLists.txt)"
}

sub IS_GENERATOR_BUILD_SYSTEM {
	return 1;
}

sub SUPPORTED_TARGET_BUILD_SYSTEMS {
	return qw(makefile ninja);
}

# Never used ?
#  -DCMAKE_INSTALL_SYSCONFDIR=/etc


sub check_auto_buildable {
	my $this=shift;
	my ($step)=@_;

        unless (ensure_debhelper_version(10, 0, 0)) {
            error "debhelper addon 'ecbuild' requires debhelper 10 or later";
        }
	if (-e $this->get_sourcepath("CMakeLists.txt")) {
		my $ret = ($step eq "configure" && 1) ||
		          $this->get_targetbuildsystem->check_auto_buildable(@_);
		if ($this->check_auto_buildable_clean_oos_buildir(@_)) {
			# Assume that the package can be cleaned (i.e. the build directory can
			# be removed) as long as it is built out-of-source tree and can be
			# configured.
			$ret++ if not $ret;
		}
		# Existence of CMakeCache.txt indicates cmake has already
		# been used by a prior build step, so should be used
		# instead of the parent makefile class.
		$ret++ if ($ret && -e $this->get_buildpath("CMakeCache.txt"));
		return $ret;
	}
	return 0;
}

sub new {
	my $class=shift;
	my $this=$class->SUPER::new(@_);
	$this->prefer_out_of_source_building(@_);
	return $this;
}

sub configure {
	my $this=shift;
	# Standard set of cmake flags
	my @flags = @STANDARD_CMAKE_FLAGS;
	my $backend = $this->get_targetbuildsystem->NAME;

	if (exists($TARGET_BUILD_SYSTEM2CMAKE_GENERATOR{$backend})) {
		my $generator = $TARGET_BUILD_SYSTEM2CMAKE_GENERATOR{$backend};
		push(@flags, "-G${generator}");
	}
        if ($ENV{DH_VERBOSE}) {
		push(@flags, "-DECBUILD_LOG_LEVEL=DEBUG");
        }
	unless ($dh{QUIET}) {
		push(@flags, "-DCMAKE_VERBOSE_MAKEFILE=ON");
	}
	if ($ENV{CC}) {
		push @flags, "-DCMAKE_C_COMPILER=" . $ENV{CC};
	}
	if ($ENV{CXX}) {
		push @flags, "-DCMAKE_CXX_COMPILER=" . $ENV{CXX};
	}
	if (is_cross_compiling()) {
		my $deb_host = dpkg_architecture_value("DEB_HOST_ARCH_OS");
		if (my $cmake_system = $DEB_HOST2CMAKE_SYSTEM{$deb_host}) {
			push(@flags, "-DCMAKE_SYSTEM_NAME=${cmake_system}");
		} else {
			error("Cannot cross-compile - CMAKE_SYSTEM_NAME not known for ${deb_host}");
		}
		my $gnu_cpu = dpkg_architecture_value("DEB_HOST_GNU_CPU");
		if (exists($GNU_CPU2SYSTEM_PROCESSOR{$gnu_cpu})) {
			push @flags, "-DCMAKE_SYSTEM_PROCESSOR=" . $GNU_CPU2SYSTEM_PROCESSOR{$gnu_cpu};
		} else {
			push @flags, "-DCMAKE_SYSTEM_PROCESSOR=${gnu_cpu}";
		}
		if (not $ENV{CC}) {
			push @flags, "-DCMAKE_C_COMPILER=" . dpkg_architecture_value("DEB_HOST_GNU_TYPE") . "-gcc";
		}
		if (not $ENV{CXX}) {
			push @flags, "-DCMAKE_CXX_COMPILER=" . dpkg_architecture_value("DEB_HOST_GNU_TYPE") . "-g++";
		}
		push(@flags, "-DPKG_CONFIG_EXECUTABLE=/usr/bin/" . dpkg_architecture_value("DEB_HOST_GNU_TYPE") . "-pkg-config");
		push(@flags, "-DPKGCONFIG_EXECUTABLE=/usr/bin/" . dpkg_architecture_value("DEB_HOST_GNU_TYPE") . "-pkg-config");
		push(@flags, "-DQMAKE_EXECUTABLE=/usr/bin/" . dpkg_architecture_value("DEB_HOST_GNU_TYPE") . "-qmake");
	}
	push(@flags, "-DCMAKE_INSTALL_LIBDIR=lib/" . dpkg_architecture_value("DEB_HOST_MULTIARCH"));

	# CMake doesn't respect CPPFLAGS, see #653916.
	if ($ENV{CPPFLAGS} && ! compat(8)) {
		$ENV{CFLAGS}   .= ' ' . $ENV{CPPFLAGS};
		$ENV{CXXFLAGS} .= ' ' . $ENV{CPPFLAGS};
	}

	$this->mkdir_builddir();
	eval { 
		$this->doit_in_builddir("cmake", @flags, @_, $this->get_source_rel2builddir());
	};
	if (my $err = $@) {
		if (-e $this->get_buildpath("CMakeCache.txt")) {
			$this->doit_in_builddir('tail', '-v', '-n', '+0', 'CMakeCache.txt');
		}
		if (-e $this->get_buildpath('CMakeFiles/CMakeOutput.log')) {
			$this->doit_in_builddir('tail', '-v', '-n', '+0', 'CMakeFiles/CMakeOutput.log');
		}
		if (-e $this->get_buildpath('CMakeFiles/CMakeError.log')) {
			$this->doit_in_builddir('tail', '-v', '-n', '+0', 'CMakeFiles/CMakeError.log');
		}
		die $err;
	}
}

sub test {
	my $this=shift;
	my $target = $this->get_targetbuildsystem;
	$ENV{CTEST_OUTPUT_ON_FAILURE} = 1;
	if ($target->NAME eq 'makefile') {
		# Unlike make, CTest does not have "unlimited parallel" setting (-j implies
		# -j1). So in order to simulate unlimited parallel, allow to fork a huge
		# number of threads instead.
		my $parallel = ($this->get_parallel() > 0) ? $this->get_parallel() : 999;
		push(@_, "ARGS+=-j$parallel")
	}
	return $this->SUPER::test(@_);
}

1
