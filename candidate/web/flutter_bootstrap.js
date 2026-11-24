{{flutter_js}}
{{flutter_build_config}}
// Keep the renderer local: no CanvasKit CDN dependency at runtime.
// Versioned entrypoint busts stale HTTP caches after a redeploy.
_flutter.buildConfig.builds.forEach((b) => {
  if (b.mainJsPath && !b.mainJsPath.includes('?')) b.mainJsPath += '?v=final1';
});
_flutter.loader.load({config: {canvasKitBaseUrl: 'canvaskit/'}});
