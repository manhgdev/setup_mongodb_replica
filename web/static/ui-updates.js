'use strict';
(() => {
  const files = ['/', '/static/language.js', '/static/app.js', '/static/data-explorer.js', '/static/styles.css', '/static/ui-updates.js'];
  let loadedVersion;
  let checking = false;
  async function checkVersion() {
    if (checking || document.hidden) return;
    checking = true;
    try {
      const versions = await Promise.all(files.map(async path => {
        // The index route serves GET only. Static files support HEAD.
        const response = await fetch(path, {method: path === '/' ? 'GET' : 'HEAD', cache: 'no-store', credentials: 'omit'});
        if (!response.ok || !response.headers.get('etag')) throw new Error();
        return response.headers.get('etag');
      }));
      const version = versions.join('|');
      if (!loadedVersion) loadedVersion = version;
      if (version === loadedVersion || document.querySelector('dialog[open], .member-name-input')) return;
      if (document.querySelector('#login-form input:focus') || [...document.querySelectorAll('#login-form input')].some(input => input.value)) return;
      location.reload();
    } catch {
      // The server may be restarting. Check again when it is available.
    } finally {
      checking = false;
    }
  }
  checkVersion();
  setInterval(checkVersion, 10000);
  document.addEventListener('visibilitychange', checkVersion);
})();
