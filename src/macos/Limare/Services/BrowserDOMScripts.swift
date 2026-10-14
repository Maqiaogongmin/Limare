import Foundation

/// All injectable JavaScript for Phase 3R1 browser_use actions.
/// Uses WKWebView.callAsyncJavaScript argument passing to prevent script injection
/// and safely formats and extracts page state.
public enum BrowserDOMScripts {

    // MARK: - Get Page Info

    public static let pageInfoScript = """
    const doc = document;
    const win = window;
    const docEl = doc.documentElement || {};
    const body = doc.body || {};
    return {
        status: 'ok',
        action: 'get_page_info',
        url: win.location ? win.location.href : '',
        title: doc.title || '',
        ready_state: doc.readyState || 'unknown',
        viewport: {
            width: win.innerWidth || 0,
            height: win.innerHeight || 0
        },
        scroll_x: win.scrollX || win.pageXOffset || 0,
        scroll_y: win.scrollY || win.pageYOffset || 0,
        document_width: docEl.scrollWidth || body.scrollWidth || 0,
        document_height: docEl.scrollHeight || body.scrollHeight || 0
    };
    """

    // MARK: - Get Text

    public static let getTextScript = """
    const sel = (typeof selector !== 'undefined' && selector) ? selector : null;
    let el = null;
    if (sel && sel.length > 0) {
        try {
            el = document.querySelector(sel);
        } catch(e) {
            return {
                status: 'error',
                error: 'Invalid selector: ' + sel
            };
        }
        if (!el) {
            return {
                status: 'error',
                error: 'Element not found: ' + sel
            };
        }
    } else {
        el = document.body || document.documentElement;
    }

    if (!el) {
        return {
            status: 'ok',
            trust: 'untrusted_web_content',
            action: 'get_text',
            text: '',
            length: 0,
            truncated: false
        };
    }

    const tag = (el.tagName || '').toLowerCase();
    const type = (el.getAttribute('type') || '').toLowerCase();
    const autocomplete = (el.getAttribute('autocomplete') || '').toLowerCase();
    const isSensitive = (type === 'password' ||
                         autocomplete === 'current-password' ||
                         autocomplete === 'new-password' ||
                         autocomplete === 'one-time-code');
    const isFormOrEditable = (tag === 'input' ||
                              tag === 'textarea' ||
                              tag === 'select' ||
                              el.isContentEditable ||
                              el.getAttribute('contenteditable') === 'true' ||
                              el.getAttribute('contenteditable') === '');

    // PRIVACY GUARANTEE: Never return .value or user-entered text for input/textarea/select/contenteditable or sensitive elements!
    let raw = '';
    if (isFormOrEditable || isSensitive) {
        raw = '';
    } else {
        const clone = el.cloneNode(true);
        const forms = clone.querySelectorAll('input, textarea, select, [contenteditable="true"], [contenteditable=""], [contenteditable]');
        for (let f = 0; f < forms.length; f++) {
            if (forms[f].parentNode) {
                forms[f].parentNode.removeChild(forms[f]);
            }
        }
        raw = clone.innerText || clone.textContent || '';
    }

    const max = (typeof maxChars !== 'undefined' && maxChars) ? maxChars : 40000;
    const truncated = raw.length > max;
    const content = truncated ? raw.substring(0, max) : raw;

    return {
        status: 'ok',
        trust: 'untrusted_web_content',
        action: 'get_text',
        selector: sel || null,
        text: content,
        length: content.length,
        total_length: raw.length,
        truncated: truncated
    };
    """

    // MARK: - Get Readable

    public static let getReadableScript = """
    const candidateSelectors = [
        'article',
        '[role="main"]',
        'main',
        '.post-content',
        '.article-body',
        '.entry-content',
        '#content',
        '.content'
    ];
    let target = null;
    let matchedSelector = null;
    for (let i = 0; i < candidateSelectors.length; i++) {
        const found = document.querySelector(candidateSelectors[i]);
        if (found && window.getComputedStyle(found).display !== 'none' && (found.innerText || '').trim().length > 0) {
            target = found;
            matchedSelector = candidateSelectors[i];
            break;
        }
    }
    if (!target) {
        target = document.body || document.documentElement;
        matchedSelector = 'body (fallback)';
    }

    if (!target) {
        return {
            status: 'ok',
            trust: 'untrusted_web_content',
            action: 'get_readable',
            title: document.title || '',
            text: '',
            length: 0,
            truncated: false
        };
    }

    const clone = target.cloneNode(true);
    // Remove noisy / sensitive / non-content / form / editable tags
    const removeTags = ['script', 'style', 'noscript', 'svg', 'canvas', 'nav', 'header', 'footer', 'input', 'textarea', 'select'];
    for (let t = 0; t < removeTags.length; t++) {
        const badEls = clone.querySelectorAll(removeTags[t]);
        for (let b = 0; b < badEls.length; b++) {
            if (badEls[b].parentNode) {
                badEls[b].parentNode.removeChild(badEls[b]);
            }
        }
    }
    const editables = clone.querySelectorAll('[contenteditable="true"], [contenteditable=""], [contenteditable]');
    for (let e = 0; e < editables.length; e++) {
        if (editables[e].parentNode) {
            editables[e].parentNode.removeChild(editables[e]);
        }
    }

    const raw = (clone.innerText || clone.textContent || '').replace(/\\s+/g, ' ').trim();
    const max = (typeof maxChars !== 'undefined' && maxChars) ? maxChars : 40000;
    const truncated = raw.length > max;
    const content = truncated ? raw.substring(0, max) : raw;

    return {
        status: 'ok',
        trust: 'untrusted_web_content',
        action: 'get_readable',
        title: document.title || '',
        matched_container: matchedSelector,
        text: content,
        length: content.length,
        total_length: raw.length,
        truncated: truncated
    };
    """

    // MARK: - Find Elements

    public static let findElementsScript = """
    const customSel = (typeof selector !== 'undefined' && selector) ? selector : null;
    const query = customSel && customSel.length > 0
        ? customSel
        : 'a, button, input, textarea, select, [role="button"], [role="link"], [contenteditable="true"]';
    let nodeList;
    try {
        nodeList = document.querySelectorAll(query);
    } catch(e) {
        return {
            status: 'error',
            error: 'Invalid selector query: ' + query
        };
    }

    function isVisible(el) {
        if (!el || !el.getBoundingClientRect) return false;
        const style = window.getComputedStyle(el);
        if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return false;
        const rect = el.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0;
    }

    function computeSelector(el) {
        if (el.id && /^[A-Za-z][A-Za-z0-9_-]*$/.test(el.id)) {
            const byId = '#' + el.id;
            if (document.querySelectorAll(byId).length === 1) return byId;
        }
        const testId = el.getAttribute('data-testid');
        if (testId) {
            const byTest = '[data-testid="' + testId.replace(/"/g, '\\\\"') + '"]';
            if (document.querySelectorAll(byTest).length === 1) return byTest;
        }
        const name = el.getAttribute('name');
        if (name) {
            const byName = el.tagName.toLowerCase() + '[name="' + name.replace(/"/g, '\\\\"') + '"]';
            if (document.querySelectorAll(byName).length === 1) return byName;
        }
        const aria = el.getAttribute('aria-label');
        if (aria) {
            const byAria = '[' + 'aria-label="' + aria.replace(/"/g, '\\\\"') + '"]';
            if (document.querySelectorAll(byAria).length === 1) return byAria;
        }
        const placeholder = el.getAttribute('placeholder');
        if (placeholder) {
            const byPh = el.tagName.toLowerCase() + '[placeholder="' + placeholder.replace(/"/g, '\\\\"') + '"]';
            if (document.querySelectorAll(byPh).length === 1) return byPh;
        }
        if (el.className && typeof el.className === 'string') {
            const classes = el.className.trim().split(/\\s+/).filter(function(c) {
                return /^[A-Za-z0-9_-]+$/.test(c) && !c.includes(':');
            });
            if (classes.length > 0) {
                const classSel = el.tagName.toLowerCase() + '.' + classes.slice(0, 2).join('.');
                if (document.querySelectorAll(classSel).length === 1) return classSel;
            }
        }
        const path = [];
        let cur = el;
        while (cur && cur.nodeType === 1 && cur !== document.documentElement && cur !== document.body && path.length < 5) {
            const tag = cur.tagName.toLowerCase();
            const parent = cur.parentNode;
            if (parent) {
                const siblings = parent.children;
                let index = 1;
                for (let i = 0; i < siblings.length; i++) {
                    if (siblings[i] === cur) break;
                    if (siblings[i].tagName === cur.tagName) index++;
                }
                path.unshift(tag + ':nth-of-type(' + index + ')');
            } else {
                path.unshift(tag);
            }
            cur = parent;
        }
        return path.join(' > ') || el.tagName.toLowerCase();
    }

    const elements = [];
    const limit = (typeof maxElements !== 'undefined' && maxElements) ? maxElements : 100;
    for (let i = 0; i < nodeList.length && elements.length < limit; i++) {
        const el = nodeList[i];
        if (!isVisible(el)) continue;

        const tag = el.tagName.toLowerCase();
        const type = (el.getAttribute('type') || '').toLowerCase();
        const name = el.getAttribute('name') || null;
        const ariaLabel = el.getAttribute('aria-label') || null;
        const placeholder = el.getAttribute('placeholder') || null;
        const href = el.getAttribute('href') || null;
        const disabled = el.disabled === true || el.getAttribute('aria-disabled') === 'true';
        const selector = computeSelector(el);

        const autocomplete = (el.getAttribute('autocomplete') || '').toLowerCase();
        const isSensitive = (type === 'password' ||
                             autocomplete === 'current-password' ||
                             autocomplete === 'new-password' ||
                             autocomplete === 'one-time-code');

        const isInputOrForm = (tag === 'input' ||
                               tag === 'textarea' ||
                               tag === 'select' ||
                               el.isContentEditable ||
                               el.getAttribute('contenteditable') === 'true' ||
                               el.getAttribute('contenteditable') === '');

        // PRIVACY GUARANTEE: Never return .value or user-entered text for input/textarea/select/contenteditable!
        let text = null;
        if (!isInputOrForm) {
            const rawText = (el.innerText || '').replace(/\\s+/g, ' ').trim().substring(0, 80);
            if (rawText.length > 0) {
                text = rawText;
            }
        }

        const item = {
            tag: tag,
            type: type.length > 0 ? type : null,
            name: name,
            text: text,
            aria_label: ariaLabel,
            placeholder: placeholder,
            href: href,
            disabled: disabled,
            selector: selector
        };
        if (isSensitive) {
            item.sensitive = true;
        }
        elements.push(item);
    }

    return {
        status: 'ok',
        trust: 'untrusted_web_content',
        action: 'find_elements',
        total_matched: nodeList.length,
        returned_count: elements.length,
        elements: elements
    };
    """

    // MARK: - Click

    public static let clickScript = """
    const sel = (typeof selector !== 'undefined' && selector) ? selector : null;
    let el = null;
    try {
        el = document.querySelector(sel);
    } catch(e) {
        return { status: 'error', error: 'Invalid selector: ' + sel };
    }
    if (!el) {
        return { status: 'error', error: 'Element not found: ' + sel };
    }
    if (el.disabled || el.getAttribute('aria-disabled') === 'true') {
        return { status: 'error', error: 'Element is disabled', tag: el.tagName };
    }

    if (el.scrollIntoView) {
        el.scrollIntoView({ behavior: 'instant', block: 'center', inline: 'center' });
    }

    const bOpts = { bubbles: true, cancelable: true, view: window };
    el.dispatchEvent(new MouseEvent('mouseover', bOpts));
    el.dispatchEvent(new MouseEvent('mouseenter', { bubbles: false, cancelable: true, view: window }));
    el.dispatchEvent(new MouseEvent('mousemove', bOpts));
    el.dispatchEvent(new MouseEvent('mousedown', bOpts));
    el.dispatchEvent(new MouseEvent('mouseup', bOpts));
    el.click();
    el.dispatchEvent(new MouseEvent('mouseleave', { bubbles: false, cancelable: true, view: window }));
    el.dispatchEvent(new MouseEvent('mouseout', bOpts));

    return {
        status: 'ok',
        action: 'click',
        clicked: true,
        selector: sel,
        tag: el.tagName.toLowerCase()
    };
    """

    // MARK: - Type

    public static let typeScript = """
    const sel = (typeof selector !== 'undefined' && selector) ? selector : null;
    const textToType = (typeof text !== 'undefined' && text) ? text : '';
    let el = null;
    try {
        el = document.querySelector(sel);
    } catch(e) {
        return { status: 'error', error: 'Invalid selector: ' + sel };
    }
    if (!el) {
        return { status: 'error', error: 'Element not found: ' + sel };
    }
    if (el.disabled || el.getAttribute('aria-disabled') === 'true' || el.readOnly) {
        return { status: 'error', error: 'Element is disabled or readonly', tag: el.tagName };
    }

    const tag = el.tagName.toUpperCase();
    const typeAttr = (el.getAttribute('type') || '').toLowerCase();
    const autocomplete = (el.getAttribute('autocomplete') || '').toLowerCase();

    // Sensitive & Password protection
    if (typeAttr === 'password' ||
        autocomplete === 'current-password' ||
        autocomplete === 'new-password' ||
        autocomplete === 'one-time-code') {
        return {
            status: 'error',
            code: 'password_field_requires_takeover',
            error: 'Password fields require user takeover.'
        };
    }

    if (el.focus) el.focus();

    if (tag === 'INPUT' || tag === 'TEXTAREA') {
        const nativeSetter = Object.getOwnPropertyDescriptor(
            tag === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype, 'value'
        );
        if (nativeSetter && nativeSetter.set) {
            nativeSetter.set.call(el, textToType);
        } else {
            el.value = textToType;
        }
    } else if (el.isContentEditable) {
        el.innerText = textToType;
    } else {
        return {
            status: 'error',
            error: 'Element is not an input, textarea, or contenteditable element.'
        };
    }

    // Dispatch input/change simulation
    for (let i = 0; i < textToType.length; i++) {
        const c = textToType[i];
        el.dispatchEvent(new KeyboardEvent('keydown', { key: c, bubbles: true }));
        el.dispatchEvent(new KeyboardEvent('keypress', { key: c, bubbles: true }));
        el.dispatchEvent(new InputEvent('input', { data: c, inputType: 'insertText', bubbles: true }));
        el.dispatchEvent(new KeyboardEvent('keyup', { key: c, bubbles: true }));
    }
    el.dispatchEvent(new Event('change', { bubbles: true }));

    return {
        status: 'ok',
        action: 'type',
        selector: sel,
        typed_characters: textToType.length
    };
    """

    // MARK: - Scroll

    public static let scrollScript = """
    const targetSel = (typeof selector !== 'undefined' && selector) ? selector : null;
    const dir = (typeof direction !== 'undefined' && direction) ? direction : 'down';
    const amt = (typeof amount !== 'undefined' && amount) ? amount : 600;
    const px = (dir === 'up') ? -amt : amt;
    const docEl = document.documentElement || {};
    const body = document.body || {};

    if (targetSel && targetSel.length > 0) {
        const el = document.querySelector(targetSel);
        if (!el) {
            return { status: 'error', error: 'Element not found: ' + targetSel };
        }
        el.scrollTop += px;
        return {
            status: 'ok',
            action: 'scroll',
            direction: dir,
            amount: amt,
            scroll_y: el.scrollTop,
            document_height: el.scrollHeight,
            viewport_height: el.clientHeight
        };
    } else {
        window.scrollBy(0, px);
        return {
            status: 'ok',
            action: 'scroll',
            direction: dir,
            amount: amt,
            scroll_y: window.scrollY || window.pageYOffset || 0,
            document_height: docEl.scrollHeight || body.scrollHeight || 0,
            viewport_height: window.innerHeight || 0
        };
    }
    """

    // MARK: - Wait for DOM Stable

    public static func setupMutationObserver() -> String {
        """
        (function() {
            window.__limareDomMutations = 0;
            if (window.__limareObserver) {
                try { window.__limareObserver.disconnect(); } catch(e) {}
            }
            window.__limareObserver = new MutationObserver(function(muts) {
                window.__limareDomMutations += muts.length;
            });
            window.__limareObserver.observe(document.documentElement || document.body, {
                childList: true, subtree: true, attributes: true, characterData: true
            });
            return 'ok';
        })()
        """
    }
}
