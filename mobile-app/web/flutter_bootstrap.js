{{flutter_js}}
{{flutter_build_config}}

const activeBuild = _flutter.buildConfig.builds[0];
activeBuild.mainJsPath = `${activeBuild.mainJsPath}?v=${Date.now()}`;

_flutter.loader.load();
