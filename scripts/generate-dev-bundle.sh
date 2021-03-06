#!/bin/bash

set -e
set -u

UNAME=$(uname)
ARCH=$(uname -m)

if [ "$UNAME" == "Linux" ] ; then
    if [ "$ARCH" != "i686" -a "$ARCH" != "x86_64" ] ; then
        echo "Unsupported architecture: $ARCH"
        echo "Meteor only supports i686 and x86_64 for now."
        exit 1
    fi

    OS="linux"

    stripBinary() {
        strip --remove-section=.comment --remove-section=.note $1
    }
elif [ "$UNAME" == "Darwin" ] ; then
    SYSCTL_64BIT=$(sysctl -n hw.cpu64bit_capable 2>/dev/null || echo 0)
    if [ "$ARCH" == "i386" -a "1" != "$SYSCTL_64BIT" ] ; then
        # some older macos returns i386 but can run 64 bit binaries.
        # Probably should distribute binaries built on these machines,
        # but it should be OK for users to run.
        ARCH="x86_64"
    fi

    if [ "$ARCH" != "x86_64" ] ; then
        echo "Unsupported architecture: $ARCH"
        echo "Meteor only supports x86_64 for now."
        exit 1
    fi

    OS="osx"

    # We don't strip on Mac because we don't know a safe command. (Can't strip
    # too much because we do need node to be able to load objects like
    # fibers.node.)
    stripBinary() {
        true
    }
else
    echo "This OS not yet supported"
    exit 1
fi

PLATFORM="${UNAME}_${ARCH}"

# save off meteor checkout dir as final target
cd "`dirname "$0"`"/..
CHECKOUT_DIR=`pwd`

# Read the bundle version from the meteor shell script.
BUNDLE_VERSION=$(perl -ne 'print $1 if /BUNDLE_VERSION=(\S+)/' meteor)
if [ -z "$BUNDLE_VERSION" ]; then
    echo "BUNDLE_VERSION not found"
    exit 1
fi
echo "Building dev bundle $BUNDLE_VERSION"

DIR=`mktemp -d -t generate-dev-bundle-XXXXXXXX`
trap 'rm -rf "$DIR" >/dev/null 2>&1' 0

echo BUILDING IN "$DIR"

cd "$DIR"
chmod 755 .
umask 022
mkdir build
cd build

TEMP_PREFIX="$DIR/build/prefix"
mkdir -p $TEMP_PREFIX

# Add $DIR/bin and $TEMP_PREFIX/bin to $PATH so that we can use tools
# installed earlier when building later tools (namely, autoconf and
# automake for watchman, and node and npm for the various NPM packages we
# install below).
export PATH="$DIR/bin:$PATH"
PATH="$TEMP_PREFIX/bin:$PATH"

# Build reliable versions of m4, autoconf, and automake for watchman and
# potentially other projects.

M4_VERSION="1.4.17"
curl "http://ftp.gnu.org/gnu/m4/m4-$M4_VERSION.tar.gz" | gzip -d | tar x
pushd "m4-$M4_VERSION"
./configure --prefix="$TEMP_PREFIX"
make install
popd

AUTOCONF_VERSION="2.69"
curl "http://ftp.gnu.org/gnu/autoconf/autoconf-$AUTOCONF_VERSION.tar.gz" | gzip -d | tar x
pushd "autoconf-$AUTOCONF_VERSION"
./configure --prefix="$TEMP_PREFIX"
make install
popd

AUTOMAKE_VERSION="1.14"
curl "http://ftp.gnu.org/gnu/automake/automake-$AUTOMAKE_VERSION.tar.gz" | gzip -d | tar x
pushd "automake-$AUTOMAKE_VERSION"
./configure --prefix="$TEMP_PREFIX"
make install
popd

WATCHMAN_VERSION="3.0.0"
curl "https://codeload.github.com/facebook/watchman/tar.gz/v$WATCHMAN_VERSION" | gzip -d | tar x
pushd "watchman-$WATCHMAN_VERSION"
./autogen.sh
./configure --prefix="$DIR" --without-pcre
make install
strip "$DIR/bin/watchman"
popd

# Clean up some unnecessary megabytes of docs.
rm -rf "$DIR/share/doc" "$DIR/share/man"

which watchman

# ios-sim is used to run iPhone simulator from the command-line. Doesn't make
# sense to build it for linux.
if [ "$OS" == "osx" ]; then
    # the build from source is not going to work on old OS X versions, until we
    # upgrade our Mac OS X Jenkins machine, download the precompiled tarball

    # which rake # rake is required to build ios-sim
    # git clone https://github.com/phonegap/ios-sim.git
    # cd ios-sim
    # git checkout 2.0.1
    # rake build
    # which build/Release/ios-sim # check that we have in fact got the binary
    # mkdir -p "$DIR/lib/ios-sim"
    # cp -r build/Release/* "$DIR/lib/ios-sim/"

    # Download the precompiled tarball
    IOS_SIM_URL="http://android-bundle.s3.amazonaws.com/ios-sim.tgz"
    curl "$IOS_SIM_URL" | tar xfz -
    mkdir -p "$DIR/lib/ios-sim"
    cp -r ios-sim/ios-sim "$DIR/lib/ios-sim"
fi


cd "$DIR/build"

# For now, use our fork with https://github.com/npm/npm/pull/5821/files
git clone https://github.com/meteor/node.git
cd node
# When upgrading node versions, also update the values of MIN_NODE_VERSION at
# the top of tools/main.js and tools/server/boot.js, and the text in
# docs/client/full-api/concepts.html and the README in tools/bundler.js.
git checkout v0.10.33-with-npm-5821

./configure --prefix="$DIR"
make -j4
make install PORTABLE=1
# PORTABLE=1 is a node hack to make npm look relative to itself instead
# of hard coding the PREFIX.

which node

which npm

# When adding new node modules (or any software) to the dev bundle,
# remember to update LICENSE.txt! Also note that we include all the
# packages that these depend on, so watch out for new dependencies when
# you update version numbers.

# First, we install the modules that are dependencies of tools/server/boot.js:
# the modules that users of 'meteor bundle' will also have to install. We save a
# shrinkwrap file with it, too.  We do this in a separate place from
# $DIR/lib/node_modules originally, because otherwise 'npm shrinkwrap' will get
# confused by the pre-existing modules.
#
# Some notes on upgrading modules in this file (which can't contain comments,
# sad):
#  - Fibers 1.0.2 is out but introduces a bug that's been fixed on master
#    but unreleased: https://github.com/laverdet/node-fibers/pull/189
#    We will definitely need to upgrade in order to support Node 0.12 when
#    it's out, though.
#  - Not yet upgrading Underscore from 1.5.2 to 1.7.0 (which should be done
#    in the package too) because we should consider using lodash instead
#    (and there are backwards-incompatible changes either way).
mkdir "${DIR}/build/npm-install"
cd "${DIR}/build/npm-install"
cp "${CHECKOUT_DIR}/scripts/dev-bundle-package.json" package.json
npm install
npm shrinkwrap

# This ignores the stuff in node_modules/.bin, but that's OK.
cp -R node_modules/* "${DIR}/lib/node_modules/"
mkdir "${DIR}/etc"
mv package.json npm-shrinkwrap.json "${DIR}/etc/"

# Fibers ships with compiled versions of its C code for a dozen platforms. This
# bloats our dev bundle, and confuses dpkg-buildpackage and rpmbuild into
# thinking that the packages need to depend on both 32- and 64-bit versions of
# libstd++. Remove all the ones other than our architecture. (Expression based
# on build.js in fibers source.)
# XXX We haven't used dpkg-buildpackge or rpmbuild in ages. If we remove this,
#     will it let you skip the "npm install fibers" step for running bundles?
cd "$DIR/lib/node_modules/fibers/bin"
FIBERS_ARCH=$(node -p -e 'process.platform + "-" + process.arch + "-v8-" + /[0-9]+\.[0-9]+/.exec(process.versions.v8)[0]')
mv $FIBERS_ARCH ..
rm -rf *
mv ../$FIBERS_ARCH .

# Now, install the rest of the npm modules, which are only used by the 'meteor'
# tool (and not by the bundled app boot.js script).
cd "${DIR}/lib"
npm install request@2.47.0

npm install fstream@1.0.2

npm install tar@1.0.2

npm install kexec@0.2.0

npm install source-map@0.1.40

npm install browserstack-webdriver@2.41.1
rm -rf node_modules/browserstack-webdriver/docs
rm -rf node_modules/browserstack-webdriver/lib/test

npm install node-inspector@0.7.4

npm install sane@1.0.0-rc1

npm install chalk@0.5.1

npm install sqlite3@3.0.2
rm -rf node_modules/sqlite3/deps

npm install netroute@0.2.5

# Clean up a big zip file it leaves behind.
npm install phantomjs@1.9.12
rm -rf node_modules/phantomjs/tmp

npm install http-proxy@1.6.0

# XXX We ought to be able to get this from the copy in js-analyze rather than in
# the dev bundle.)
npm install esprima@1.2.2
rm -rf node_modules/esprima/test

# 2.4.0 (more or less, the package.json change isn't committed) plus our PR
# https://github.com/williamwicks/node-eachline/pull/4
npm install https://github.com/meteor/node-eachline/tarball/ff89722ff94e6b6a08652bf5f44c8fffea8a21da

# Cordova npm tool for mobile integration
# XXX We install our own fork of cordova because we need a particular patch that
# didn't land to cordova-android yet. As soon as it lands, we can switch back to
# upstream.
# https://github.com/apache/cordova-android/commit/445ddd89fb3269a772978a9860247065e5886249
#npm install cordova@3.5.0-0.2.6
npm install "https://github.com/meteor/cordova-cli/tarball/0c9b3362c33502ef8f6dba514b87279b9e440543"
rm -rf node_modules/cordova/node_modules/cordova-lib/node_modules/cordova-js/node_modules/browserify/node_modules/browser-pack/node_modules/JSONStream/test/fixtures
rm -rf node_modules/cordova/node_modules/cordova-lib/node_modules/cordova-js/node_modules/browserify/node_modules/browserify-zlib/node_modules/pako/benchmark
rm -rf node_modules/cordova/node_modules/cordova-lib/node_modules/cordova-js/node_modules/browserify/node_modules/browserify-zlib/node_modules/pako/test
rm -rf node_modules/cordova/node_modules/cordova-lib/node_modules/cordova-js/node_modules/browserify/node_modules/buffer/perf
rm -rf node_modules/cordova/node_modules/cordova-lib/node_modules/cordova-js/node_modules/browserify/node_modules/crypto-browserify/test
rm -rf node_modules/cordova/node_modules/cordova-lib/node_modules/cordova-js/node_modules/browserify/node_modules/derequire/node_modules/esprima-fb/test
rm -rf node_modules/cordova/node_modules/cordova-lib/node_modules/cordova-js/node_modules/browserify/node_modules/derequire/node_modules/esrefactor/node_modules/esprima/test
rm -rf node_modules/cordova/node_modules/cordova-lib/node_modules/cordova-js/node_modules/browserify/node_modules/insert-module-globals/node_modules/lexical-scope/node_modules/astw/node_modules/esprima-fb/test
rm -rf node_modules/cordova/node_modules/cordova-lib/node_modules/cordova-js/node_modules/browserify/node_modules/module-deps/node_modules/detective/node_modules/escodegen/node_modules/esprima/test
rm -rf node_modules/cordova/node_modules/cordova-lib/node_modules/cordova-js/node_modules/browserify/node_modules/module-deps/node_modules/detective/node_modules/esprima-fb/test
rm -rf node_modules/cordova/node_modules/cordova-lib/node_modules/cordova-js/node_modules/browserify/node_modules/syntax-error/node_modules/esprima-fb/test
rm -rf node_modules/cordova/node_modules/cordova-lib/node_modules/cordova-js/node_modules/browserify/node_modules/umd/node_modules/ruglify/test

# Checkout and build mongodb.
# We want to build a binary that includes SSL support but does not depend on a
# particular version of openssl on the host system.

cd "$DIR/build"
OPENSSL="openssl-1.0.1j"
OPENSSL_URL="http://www.openssl.org/source/$OPENSSL.tar.gz"
wget $OPENSSL_URL || curl -O $OPENSSL_URL
tar xzf $OPENSSL.tar.gz

cd $OPENSSL
if [ "$UNAME" == "Linux" ]; then
    ./config --prefix="$DIR/build/openssl-out" no-shared
else
    # This configuration line is taken from Homebrew formula:
    # https://github.com/mxcl/homebrew/blob/master/Library/Formula/openssl.rb
    ./Configure no-shared zlib-dynamic --prefix="$DIR/build/openssl-out" darwin64-x86_64-cc enable-ec_nistp_64_gcc_128
fi
make install

# To see the mongo changelog, go to http://www.mongodb.org/downloads,
# click 'changelog' under the current version, then 'release notes' in
# the upper right.
cd "$DIR/build"
MONGO_VERSION="2.4.12"

# We use Meteor fork since we added some changes to the building script.
# Our patches allow us to link most of the libraries statically.
git clone git://github.com/meteor/mongo.git
cd mongo
git checkout ssl-r$MONGO_VERSION

# Compile

MONGO_FLAGS="--ssl --release -j4 "
MONGO_FLAGS+="--cpppath=$DIR/build/openssl-out/include --libpath=$DIR/build/openssl-out/lib "

if [ "$OS" == "osx" ]; then
    # NOTE: '--64' option breaks the compilation, even it is on by default on x64 mac: https://jira.mongodb.org/browse/SERVER-5575
    MONGO_FLAGS+="--openssl=$DIR/build/openssl-out/lib "
    /usr/local/bin/scons $MONGO_FLAGS mongo mongod
elif [ "$OS" == "linux" ]; then
    MONGO_FLAGS+="--no-glibc-check --prefix=./ "
    if [ "$ARCH" == "x86_64" ]; then
      MONGO_FLAGS+="--64"
    fi
    scons $MONGO_FLAGS mongo mongod
else
    echo "We don't know how to compile mongo for this platform"
    exit 1
fi

# Copy binaries
mkdir -p "$DIR/mongodb/bin"
cp mongo "$DIR/mongodb/bin/"
cp mongod "$DIR/mongodb/bin/"

# Copy mongodb distribution information
find ./distsrc -maxdepth 1 -type f -exec cp '{}' ../mongodb \;

cd "$DIR"
stripBinary bin/node
stripBinary mongodb/bin/mongo
stripBinary mongodb/bin/mongod

# Download BrowserStackLocal binary.
BROWSER_STACK_LOCAL_URL="http://browserstack-binaries.s3.amazonaws.com/BrowserStackLocal-07-03-14-$OS-$ARCH.gz"

cd "$DIR/build"
curl -O $BROWSER_STACK_LOCAL_URL
gunzip BrowserStackLocal*
mv BrowserStackLocal* BrowserStackLocal
mv BrowserStackLocal "$DIR/bin/"

echo BUNDLING

cd "$DIR"
echo "${BUNDLE_VERSION}" > .bundle_version.txt
rm -rf build

tar czf "${CHECKOUT_DIR}/dev_bundle_${PLATFORM}_${BUNDLE_VERSION}.tar.gz" .

echo DONE
