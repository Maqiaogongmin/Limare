// A classic script, not a module: it runs even when part of the module graph fails to load on a
// bad network (which otherwise leaves a blank page forever) and offers a reload instead.
// main.js sets window.limareStarted once every module has loaded and run.
(function () {
  // Reads the same string table as i18n.js; this script cannot import it.
  var strings = {};
  try { strings = JSON.parse(document.getElementById('limare-strings').textContent || '{}'); } catch (error) {}
  function t(key) { return strings[key] || key; }

  function offerReload() {
    if (window.limareStarted) return;
    var app = document.getElementById('app');
    if (!app) return;
    var box = document.createElement('div');
    box.className = 'loading';
    box.append(t('The network is slow and the page did not load completely.') + ' ');
    var button = document.createElement('button');
    button.className = 'small';
    button.textContent = t('Reload');
    button.addEventListener('click', function () { location.reload(); });
    box.append(button);
    app.replaceChildren(box);
  }
  // A module script that fails to load fires `error` on its element; it does not bubble.
  document.addEventListener('error', function (event) {
    if (event.target && event.target.tagName === 'SCRIPT') offerReload();
  }, true);
  setTimeout(offerReload, 30000);
})();
