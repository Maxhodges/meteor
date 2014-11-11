var _ = require('underscore');
var path = require('path');

var buildmessage = require('./buildmessage.js');
var catalog = require('./catalog.js');
var compiler = require('./compiler.js');
var files = require('./files.js');
var isopackCompiler = require('./isopack-compiler.js');
var isopackModule = require('./isopack.js');
var watch = require('./watch.js');

exports.IsopackCache = function (options) {
  var self = this;
  options = options || {};
  // cacheDir may be null; in this case, we just don't ever save things to disk.
  self.cacheDir = options.cacheDir;
  // tropohouse may be null; in this case, we can't load versioned packages.
  // eg, for building isopackets.
  self.tropohouse = options.tropohouse;
  self.isopacks = {};

  if (self.cacheDir)
    files.mkdir_p(self.cacheDir);
};

_.extend(exports.IsopackCache.prototype, {
  buildLocalPackages: function (packageMap, rootPackageNames) {
    var self = this;
    buildmessage.assertInCapture();

    var onStack = {};
    if (rootPackageNames) {
      _.each(rootPackageNames, function (name) {
        self._ensurePackageBuilt(name, packageMap, onStack);
      });
    } else {
      packageMap.eachPackage(function (name, packageInfo) {
        self._ensurePackageBuilt(name, packageMap, onStack);
      });
    }
  },

  // Returns the isopack (already loaded in memory) for a given name. It is an
  // error to call this if it's not already loaded! So it should only be called
  // after buildLocalPackages has returned, or in the process of building a
  // package whose dependencies have all already been built.
  getIsopack: function (name) {
    var self = this;
    if (! _.has(self.isopacks, name))
      throw Error("isopack " + name + " not yet built?");
    return self.isopacks[name];
  },

  // XXX #3006 Don't infinite recurse on circular deps
  _ensurePackageBuilt: function (name, packageMap, onStack) {
    var self = this;
    buildmessage.assertInCapture();
    if (_.has(self.isopacks, name))
      return;

    var packageInfo = packageMap.getInfo(name);
    if (! packageInfo)
      throw Error("Depend on unknown package " + name + "?");

    if (packageInfo.kind === 'local') {
      var packageNames =
            packageInfo.packageSource.getPackagesToBuildFirst(packageMap);
      _.each(packageNames, function (depName) {
        if (_.has(onStack, depName)) {
          buildmessage.error("circular dependency between packages " +
                             name + " and " + depName);
          // recover by not enforcing one of the dependencies
          return;
        }
        onStack[depName] = true;
        self._ensurePackageBuilt(depName, packageMap, onStack);
        delete onStack[depName];
      });

      self._loadLocalPackage(name, packageInfo, packageMap);
    } else if (packageInfo.kind === 'versioned') {
      // We don't have to build this package, and we don't have to build its
      // dependencies either! Just load it from disk.

      if (!self.tropohouse) {
        throw Error("Can't load versioned packages without a tropohouse!");
      }

      // Load the isopack from disk.
      buildmessage.enterJob(
        "loading package " + name + "@" + packageInfo.version,
        function () {
          var isopackPath = self.tropohouse.packagePath(
            name, packageInfo.version);
          var isopack = new isopackModule.Isopack();
          isopack.initFromPath(name, isopackPath);
          self.isopacks[name] = isopack;
        });
    } else {
      throw Error("unknown packageInfo kind?");
    }
  },

  _loadLocalPackage: function (name, packageInfo, packageMap) {
    var self = this;
    buildmessage.assertInCapture();
    buildmessage.enterJob("building package " + name, function () {
      // Do we have an up-to-date package on disk?
      var isopackBuildInfoJson = self.cacheDir && files.readJSONOrNull(
        self._isopackBuildInfoPath(name));
      var upToDate = self._checkUpToDate({
        isopackBuildInfoJson: isopackBuildInfoJson,
        packageMap: packageMap
      });

      if (upToDate) {
        var isopack = new isopackModule.Isopack;
        isopack.initFromPath(name, self._isopackDir(name), {
          isopackBuildInfoJson: isopackBuildInfoJson
        });
        self.isopacks[name] = isopack;
        return;
      }

      // Nope! Compile it again.
      var compilerResult = isopackCompiler.compile(packageInfo.packageSource, {
        packageMap: packageMap,
        isopackCache: self
      });
      if (buildmessage.jobHasMessages()) {
        // recover by adding an empty package
        self.isopacks[name] = new isopackModule.Isopack;
        self.isopacks[name].initEmpty(name);
        return;
      }

      var pluginProviderPackageMap = packageMap.makeSubsetMap(
        compilerResult.pluginProviderPackageNames);
      if (self.cacheDir) {
        // Save to disk, for next time!
        compilerResult.isopack.saveToPath(self._isopackDir(name), {
          pluginProviderPackageMap: pluginProviderPackageMap,
          includeIsopackBuildInfo: true
        });
      }

      self.isopacks[name] = compilerResult.isopack;
    });
  },

  _checkUpToDate: function (options) {
    var self = this;
    // If there isn't an isopack-buildinfo.json file, then we definitely aren't
    // up to date!
    if (! options.isopackBuildInfoJson)
      return false;
    // If any of the direct dependencies changed their version or location, we
    // aren't up to date.
    if (!options.packageMap.isSupersetOfJSON(
      options.isopackBuildInfoJson.pluginProviderPackageMap)) {
      return false;
    }
    // Merge in the watchsets for all unibuilds and plugins in the package, then
    // check it once.
    var watchSet = watch.WatchSet.fromJSON(
      options.isopackBuildInfoJson.pluginDependencies);

    _.each(options.isopackBuildInfoJson.unibuildDependencies, function (deps) {
      watchSet.merge(watch.WatchSet.fromJSON(deps));
    });
    return watch.isUpToDate(watchSet);
  },

  _isopackDir: function (packageName) {
    var self = this;
    return path.join(self.cacheDir, packageName);
  },

  _isopackBuildInfoPath: function (packageName) {
    var self = this;
    return path.join(self.cacheDir, packageName, 'isopack-buildinfo.json');
  }
});
