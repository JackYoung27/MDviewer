(() => {
  const contentEl = document.getElementById("content");
  const payloadEl = document.getElementById("viewer-data");
  const decoder = new TextDecoder();
  const searchState = {
    query: "",
    matches: [],
    activeIndex: -1,
    panelEl: null,
    inputEl: null,
    countEl: null,
  };
  let renderedContentHtml = "";
  let renderedRawContent = "";
  let renderedDocumentTitle = document.title;
  let mermaidRenderGeneration = 0;

  function getMode() {
    return localStorage.getItem("mdv-theme") || "auto";
  }

  function getEffectiveTheme() {
    const mode = getMode();
    if (mode === "dark" || mode === "light") return mode;
    return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }

  function updateToggleButton() {
    const btn = document.querySelector(".theme-toggle");
    if (!btn) return;
    const mode = getMode();
    if (mode === "auto") {
      btn.textContent = "\u25D1";
      btn.setAttribute("aria-label", "Theme: auto (system) \u2014 click to switch to light");
    } else if (mode === "light") {
      btn.textContent = "\u2600";
      btn.setAttribute("aria-label", "Theme: light \u2014 click to switch to dark");
    } else {
      btn.textContent = "\u263E";
      btn.setAttribute("aria-label", "Theme: dark \u2014 click to switch to auto");
    }
  }

  function applyMode(mode) {
    if (mode === "auto") {
      document.documentElement.removeAttribute("data-theme");
      localStorage.removeItem("mdv-theme");
    } else {
      document.documentElement.setAttribute("data-theme", mode);
      localStorage.setItem("mdv-theme", mode);
    }
    updateToggleButton();
    renderMermaidFigures(contentEl);
  }

  function toggleTheme() {
    const mode = getMode();
    if (mode === "auto") applyMode("light");
    else if (mode === "light") applyMode("dark");
    else applyMode("auto");
  }

  window.toggleTheme = toggleTheme;

  function initTheme() {
    const saved = localStorage.getItem("mdv-theme");
    if (saved === "dark" || saved === "light") {
      document.documentElement.setAttribute("data-theme", saved);
    }

    window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", function () {
      if (getMode() !== "auto") return;
      updateToggleButton();
      renderMermaidFigures(contentEl);
    });
  }

  function createToggleButton() {
    const btn = document.createElement("button");
    btn.className = "theme-toggle";
    btn.addEventListener("click", toggleTheme);
    document.body.appendChild(btn);
    updateToggleButton();
  }

  function updateSearchCountLabel() {
    if (!searchState.countEl) return;

    if (!searchState.query) {
      searchState.countEl.textContent = "";
      return;
    }

    if (searchState.matches.length === 0) {
      searchState.countEl.textContent = "No matches";
      return;
    }

    searchState.countEl.textContent = `${searchState.activeIndex + 1} of ${searchState.matches.length}`;
  }

  function applyRenderedContent() {
    contentEl.innerHTML = renderedContentHtml || "<p></p>";
    disableTaskCheckboxes(contentEl);
    assignHeadingIds(contentEl);
    finalizeLinks(contentEl);
    finalizeImages(contentEl);
    renderMermaidDiagrams(contentEl);
    renderMath(contentEl);
    setupCodeBlockCopy(contentEl);
    setupDirectEditableSurface();
    document.title = renderedDocumentTitle;
  }

  function clearSearchSelection() {
    for (const match of searchState.matches) {
      match.classList.remove("find-match--active");
    }

    searchState.matches = [];
    searchState.activeIndex = -1;
    updateSearchCountLabel();
  }

  function resetSearchHighlights() {
    clearSearchSelection();
    applyRenderedContent();
  }

  function escapeRegExp(value) {
    return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  }

  function collectSearchMatches(query) {
    const pattern = new RegExp(escapeRegExp(query), "gi");
    const walker = document.createTreeWalker(
      contentEl,
      NodeFilter.SHOW_TEXT,
      {
        acceptNode(node) {
          if (!node.nodeValue || !node.nodeValue.trim()) {
            return NodeFilter.FILTER_REJECT;
          }

          const parent = node.parentElement;
          if (!parent) {
            return NodeFilter.FILTER_REJECT;
          }

          if (parent.closest(".find-panel")) {
            return NodeFilter.FILTER_REJECT;
          }

          if (["SCRIPT", "STYLE", "NOSCRIPT"].includes(parent.tagName)) {
            return NodeFilter.FILTER_REJECT;
          }

          return NodeFilter.FILTER_ACCEPT;
        },
      }
    );

    const textNodes = [];
    while (walker.nextNode()) {
      textNodes.push(walker.currentNode);
    }

    const matches = [];

    for (const textNode of textNodes) {
      const text = textNode.nodeValue;
      pattern.lastIndex = 0;

      let match = pattern.exec(text);
      if (!match) continue;

      const fragment = document.createDocumentFragment();
      let lastIndex = 0;

      while (match) {
        const start = match.index;
        const end = start + match[0].length;

        if (start > lastIndex) {
          fragment.appendChild(document.createTextNode(text.slice(lastIndex, start)));
        }

        const mark = document.createElement("mark");
        mark.className = "find-match";
        mark.textContent = text.slice(start, end);
        fragment.appendChild(mark);
        matches.push(mark);

        lastIndex = end;
        match = pattern.exec(text);
      }

      if (lastIndex < text.length) {
        fragment.appendChild(document.createTextNode(text.slice(lastIndex)));
      }

      textNode.parentNode.replaceChild(fragment, textNode);
    }

    return matches;
  }

  function activateSearchMatch(index, shouldScroll = true) {
    if (searchState.matches.length === 0) {
      searchState.activeIndex = -1;
      updateSearchCountLabel();
      return;
    }

    for (const match of searchState.matches) {
      match.classList.remove("find-match--active");
    }

    const normalizedIndex = ((index % searchState.matches.length) + searchState.matches.length) % searchState.matches.length;
    const activeMatch = searchState.matches[normalizedIndex];
    activeMatch.classList.add("find-match--active");
    searchState.activeIndex = normalizedIndex;
    updateSearchCountLabel();

    if (shouldScroll) {
      activeMatch.scrollIntoView({ behavior: "auto", block: "center", inline: "nearest" });
    }
  }

  function updateSearch(query, options = {}) {
    const normalizedQuery = (query || "").trim();
    const preserveIndex = options.preserveIndex === true;
    const previousIndex = searchState.activeIndex;

    searchState.query = normalizedQuery;
    resetSearchHighlights();

    if (!normalizedQuery) {
      return;
    }

    searchState.matches = collectSearchMatches(normalizedQuery);

    if (searchState.matches.length === 0) {
      updateSearchCountLabel();
      return;
    }

    const nextIndex = preserveIndex && previousIndex >= 0 ? previousIndex : 0;
    activateSearchMatch(nextIndex, options.scrollToMatch !== false);
  }

  function jumpToSearchMatch(direction) {
    if (!searchState.query) {
      openFindBar();
      return;
    }

    if (searchState.matches.length === 0) {
      updateSearch(searchState.query, { scrollToMatch: false });
    }

    if (searchState.matches.length === 0) {
      return;
    }

    const baseIndex = searchState.activeIndex >= 0 ? searchState.activeIndex : 0;
    activateSearchMatch(baseIndex + direction);
  }

  function closeFindBar() {
    if (!searchState.panelEl) return;
    searchState.panelEl.classList.remove("find-panel--visible");
    searchState.query = "";
    if (searchState.inputEl) {
      searchState.inputEl.value = "";
    }
    resetSearchHighlights();
  }

  function openFindBar() {
    if (!searchState.panelEl || editState.active) return;
    searchState.panelEl.classList.add("find-panel--visible");
    searchState.inputEl.focus();
    searchState.inputEl.select();
    updateSearch(searchState.inputEl.value, { scrollToMatch: false });
  }

  function toggleFindBar() {
    if (!searchState.panelEl) return;

    if (searchState.panelEl.classList.contains("find-panel--visible")) {
      closeFindBar();
    } else {
      openFindBar();
    }
  }

  function createSearchPanel() {
    const panel = document.createElement("section");
    panel.className = "find-panel";
    panel.setAttribute("role", "search");
    panel.setAttribute("aria-label", "Find in document");

    const input = document.createElement("input");
    input.className = "find-panel__input";
    input.type = "search";
    input.placeholder = "Find in document";
    input.setAttribute("aria-label", "Find in document");
    input.setAttribute("spellcheck", "false");

    const count = document.createElement("p");
    count.className = "find-panel__count";
    count.setAttribute("aria-live", "polite");

    const previousButton = document.createElement("button");
    previousButton.className = "find-panel__button";
    previousButton.type = "button";
    previousButton.textContent = "\u2191";
    previousButton.setAttribute("aria-label", "Previous match");
    previousButton.addEventListener("click", () => jumpToSearchMatch(-1));

    const nextButton = document.createElement("button");
    nextButton.className = "find-panel__button";
    nextButton.type = "button";
    nextButton.textContent = "\u2193";
    nextButton.setAttribute("aria-label", "Next match");
    nextButton.addEventListener("click", () => jumpToSearchMatch(1));

    const closeButton = document.createElement("button");
    closeButton.className = "find-panel__button find-panel__button--close";
    closeButton.type = "button";
    closeButton.textContent = "\u2715";
    closeButton.setAttribute("aria-label", "Close find");
    closeButton.addEventListener("click", closeFindBar);

    input.addEventListener("input", () => updateSearch(input.value));
    input.addEventListener("keydown", (event) => {
      if (event.key === "Enter") {
        event.preventDefault();
        jumpToSearchMatch(event.shiftKey ? -1 : 1);
      } else if (event.key === "Escape") {
        event.preventDefault();
        closeFindBar();
      }
    });

    panel.append(input, count, previousButton, nextButton, closeButton);
    document.body.appendChild(panel);

    searchState.panelEl = panel;
    searchState.inputEl = input;
    searchState.countEl = count;
    updateSearchCountLabel();
  }

  function setError(message) {
    contentEl.innerHTML = "";
    const errorEl = document.createElement("p");
    errorEl.className = "document__error";
    errorEl.textContent = message;
    contentEl.appendChild(errorEl);
  }

  function decodeBase64Utf8(value) {
    const binary = window.atob(value || "");
    const bytes = new Uint8Array(binary.length);

    for (let index = 0; index < binary.length; index += 1) {
      bytes[index] = binary.charCodeAt(index);
    }

    return decoder.decode(bytes);
  }

  function applyBaseUrl(baseUrl) {
    if (!baseUrl) {
      return;
    }

    let baseEl = document.querySelector("base");
    if (!baseEl) {
      baseEl = document.createElement("base");
      document.head.prepend(baseEl);
    }

    baseEl.href = baseUrl;
  }

  // A <base href> pointing at the source file's real directory is applied
  // (see applyBaseUrl) so relative image/document links resolve correctly.
  // That same <base> also resolves bare "#fragment" hrefs against that
  // directory instead of the current preview page, so WKWebView sees a
  // real navigation to a path it was never granted sandbox read access to
  // and refuses it. Give headings ids and handle same-page "#..." clicks
  // ourselves so they never reach WebKit's navigation path.
  function slugifyHeadingText(text) {
    return (text || "")
      .toLowerCase()
      .trim()
      .replace(/[^\w\- ]+/g, "")
      .replace(/\s+/g, "-");
  }

  function assignHeadingIds(root) {
    const seen = new Map();

    for (const heading of root.querySelectorAll("h1, h2, h3, h4, h5, h6")) {
      const slug = slugifyHeadingText(heading.textContent);
      if (!slug) continue;

      const count = seen.get(slug) || 0;
      seen.set(slug, count + 1);
      heading.id = count === 0 ? slug : `${slug}-${count}`;
    }
  }

  function handleFragmentLinkClick(event) {
    const anchor = event.target.closest('a[href^="#"]');
    if (!anchor) return;

    event.preventDefault();
    const target = document.getElementById(anchor.getAttribute("href").slice(1));
    if (target) {
      target.scrollIntoView({ behavior: "auto", block: "start" });
    }
  }

  function finalizeLinks(root) {
    const anchors = root.querySelectorAll("a[href]");

    for (const anchor of anchors) {
      const href = anchor.getAttribute("href") || "";

      if (/^https?:\/\//i.test(href)) {
        anchor.setAttribute("target", "_blank");
        anchor.setAttribute("rel", "noopener noreferrer");
      }
    }
  }

  function finalizeImages(root) {
    const images = root.querySelectorAll("img");

    for (const image of images) {
      image.loading = "lazy";
      image.decoding = "async";
    }
  }

  function disableTaskCheckboxes(root) {
    const checkboxes = root.querySelectorAll('input[type="checkbox"]');

    for (const checkbox of checkboxes) {
      checkbox.disabled = true;
    }
  }

  function isMermaidCodeBlock(code) {
    const className = code.className || "";
    return /\b(language-mermaid|mermaid)\b/.test(className);
  }

  function isPlainDocumentCodeBlock(code) {
    return code.classList.contains("doc-plain__code");
  }

  function configureMermaid() {
    if (!window.mermaid) {
      return false;
    }

    window.mermaid.initialize({
      startOnLoad: false,
      securityLevel: "strict",
      theme: getEffectiveTheme() === "dark" ? "dark" : "default",
    });

    return true;
  }

  function createMermaidFigure(source) {
    const figure = document.createElement("figure");
    figure.className = "mermaid-diagram";
    figure.dataset.mermaidSource = source;
    setMermaidStatus(figure, "Rendering diagram...");

    return figure;
  }

  function setMermaidStatus(figure, message) {
    const status = document.createElement("p");
    status.className = "mermaid-diagram__status";
    status.textContent = message;
    figure.replaceChildren(status);
  }

  function setMermaidFallback(figure, source, message) {
    figure.classList.add("mermaid-diagram--error");

    const status = document.createElement("p");
    status.className = "mermaid-diagram__status";
    status.textContent = message || "Could not render Mermaid diagram.";

    const pre = document.createElement("pre");
    const code = document.createElement("code");
    code.className = "language-mermaid";
    code.textContent = source;
    pre.appendChild(code);

    figure.replaceChildren(status, pre);
  }

  function svgToDataURL(svg) {
    return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
  }

  async function renderMermaidFigure(figure, source, generation, index) {
    try {
      const id = `mdv-mermaid-${generation}-${index}`;
      const result = await window.mermaid.render(id, source);

      if (generation !== mermaidRenderGeneration) {
        return;
      }

      const svg = result.svg;

      if (!svg) {
        throw new Error("Rendered SVG was empty.");
      }

      const image = document.createElement("img");
      image.className = "mermaid-diagram__image";
      image.alt = "Mermaid diagram";
      image.decoding = "async";
      image.src = svgToDataURL(svg);

      figure.classList.remove("mermaid-diagram--error");
      figure.replaceChildren(image);
    } catch (error) {
      if (generation !== mermaidRenderGeneration) {
        return;
      }

      console.error(error);
      setMermaidFallback(figure, source, "Could not render Mermaid diagram.");
    }
  }

  function renderMermaidFigures(root) {
    const figures = Array.from(root.querySelectorAll(".mermaid-diagram[data-mermaid-source]"));
    if (figures.length === 0) {
      return;
    }

    mermaidRenderGeneration += 1;
    const generation = mermaidRenderGeneration;

    if (!configureMermaid()) {
      for (const figure of figures) {
        setMermaidFallback(figure, figure.dataset.mermaidSource || "", "Mermaid renderer is unavailable.");
      }
      return;
    }

    figures.forEach((figure, index) => {
      const source = figure.dataset.mermaidSource || "";
      figure.classList.remove("mermaid-diagram--error");
      setMermaidStatus(figure, "Rendering diagram...");
      renderMermaidFigure(figure, source, generation, index);
    });
  }

  function renderMermaidDiagrams(root) {
    const codeBlocks = Array.from(root.querySelectorAll("pre > code")).filter(isMermaidCodeBlock);

    for (const code of codeBlocks) {
      const pre = code.parentElement;
      if (!pre) continue;

      const source = code.textContent || "";
      const figure = createMermaidFigure(source);
      pre.replaceWith(figure);
    }

    renderMermaidFigures(root);
  }

  function renderMath(root) {
    if (!window.renderMathInElement) {
      return;
    }

    window.renderMathInElement(root, {
      delimiters: [
        { left: "$$", right: "$$", display: true },
        { left: "\\[", right: "\\]", display: true },
        { left: "\\(", right: "\\)", display: false },
        { left: "$", right: "$", display: false },
      ],
      ignoredTags: ["script", "noscript", "style", "textarea", "pre", "code", "option"],
      ignoredClasses: ["mermaid-diagram"],
      throwOnError: false,
    });
  }

  async function copyTextToClipboard(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      try {
        await navigator.clipboard.writeText(text);
        return;
      } catch (error) {
        console.warn(error);
      }
    }

    const textarea = document.createElement("textarea");
    textarea.value = text;
    textarea.className = "clipboard-fallback-input";
    textarea.setAttribute("readonly", "");
    document.body.appendChild(textarea);
    textarea.focus();
    textarea.select();

    try {
      if (!document.execCommand("copy")) {
        throw new Error("Copy command was rejected.");
      }
    } finally {
      textarea.remove();
    }
  }

  function hasSelectionInside(element) {
    const selection = window.getSelection();
    if (!selection || selection.isCollapsed) {
      return false;
    }

    return element.contains(selection.anchorNode) || element.contains(selection.focusNode);
  }

  const CODE_COPY_LABELS = {
    ready: "Copy code",
    copied: "Copied",
    failed: "Copy failed — try again",
  };

  function setCodeBlockCopyState(pre, state) {
    pre.dataset.copyState = state;
    const button = pre.querySelector(".code-copy-button");
    if (!button) return;

    button.dataset.copyState = state;
    const label = CODE_COPY_LABELS[state] || CODE_COPY_LABELS.ready;
    button.setAttribute("aria-label", label);
    button.title = label;
  }

  function flashCodeBlockCopyState(pre, state) {
    setCodeBlockCopyState(pre, state);
    window.clearTimeout(Number(pre.dataset.copyTimer || 0));

    const timer = window.setTimeout(() => {
      setCodeBlockCopyState(pre, "ready");
      delete pre.dataset.copyTimer;
    }, 1400);

    pre.dataset.copyTimer = String(timer);
  }

  async function copyCodeBlock(pre, code) {
    try {
      await copyTextToClipboard(code.textContent || "");
      flashCodeBlockCopyState(pre, "copied");
    } catch (error) {
      console.error(error);
      flashCodeBlockCopyState(pre, "failed");
    }
  }

  function createCopyIcon() {
    const svgNS = "http://www.w3.org/2000/svg";
    const icon = document.createElementNS(svgNS, "svg");
    icon.classList.add("code-copy-button__icon");
    icon.setAttribute("aria-hidden", "true");
    icon.setAttribute("viewBox", "0 0 24 24");
    icon.setAttribute("fill", "none");
    icon.setAttribute("stroke", "currentColor");
    icon.setAttribute("stroke-width", "1.8");
    icon.setAttribute("stroke-linecap", "round");
    icon.setAttribute("stroke-linejoin", "round");

    for (const [x, y] of [["8", "4"], ["5", "8"]]) {
      const page = document.createElementNS(svgNS, "rect");
      page.setAttribute("x", x);
      page.setAttribute("y", y);
      page.setAttribute("width", "10");
      page.setAttribute("height", "12");
      page.setAttribute("rx", "2");
      icon.appendChild(page);
    }

    return icon;
  }

  function setupCodeBlockCopy(root) {
    const codeBlocks = root.querySelectorAll("pre > code");

    for (const code of codeBlocks) {
      if (isMermaidCodeBlock(code) || isPlainDocumentCodeBlock(code)) continue;

      const pre = code.parentElement;
      if (!pre) continue;

      pre.classList.add("code-block--copyable");

      const button = document.createElement("button");
      button.className = "code-copy-button";
      button.type = "button";

      button.append(createCopyIcon());
      pre.prepend(button);
      setCodeBlockCopyState(pre, "ready");

      button.addEventListener("click", (event) => {
        event.preventDefault();
        event.stopPropagation();

        if (!hasSelectionInside(pre)) {
          copyCodeBlock(pre, code);
        }
      });
    }
  }

  // --- JSON / YAML rendering -------------------------------------------

  function escapeHtml(value) {
    return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  function highlightJSON(text) {
    const escaped = escapeHtml(text);
    return escaped.replace(
      /("(?:\\u[\da-fA-F]{4}|\\[^u]|[^\\"])*"(\s*:)?)|\b(true|false|null)\b|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)/g,
      (match, str, colon, literal) => {
        if (str) return `<span class="${colon ? "tok-key" : "tok-string"}">${match}</span>`;
        if (literal) return `<span class="${literal === "null" ? "tok-null" : "tok-bool"}">${match}</span>`;
        return `<span class="tok-number">${match}</span>`;
      }
    );
  }

  function highlightYAMLScalar(value) {
    if (!value) return "";
    let tokenClass = "tok-string";
    if (/^(true|false)$/i.test(value)) tokenClass = "tok-bool";
    else if (/^(null|~)$/i.test(value)) tokenClass = "tok-null";
    else if (/^-?\d+(\.\d+)?([eE][+-]?\d+)?$/.test(value)) tokenClass = "tok-number";
    return `<span class="${tokenClass}">${escapeHtml(value)}</span>`;
  }

  function highlightYAMLValue(rest) {
    if (!rest) return "";
    const match = rest.match(/^(\s+)(.*)$/);
    if (!match) return escapeHtml(rest);
    return `${match[1]}${highlightYAMLScalar(match[2])}`;
  }

  function highlightYAMLLine(line) {
    const commentMatch = line.match(/^(\s*)#(.*)$/);
    if (commentMatch) {
      return `${commentMatch[1]}<span class="tok-comment">#${escapeHtml(commentMatch[2])}</span>`;
    }

    const kvMatch = line.match(/^(\s*(?:-\s+)?)([^:\n]+?):(\s.*|)$/);
    if (kvMatch) {
      const [, prefix, key, rest] = kvMatch;
      return `${escapeHtml(prefix)}<span class="tok-key">${escapeHtml(key)}</span>:${highlightYAMLValue(rest)}`;
    }

    const listMatch = line.match(/^(\s*-\s+)(.*)$/);
    if (listMatch) {
      return `${escapeHtml(listMatch[1])}${highlightYAMLScalar(listMatch[2])}`;
    }

    return escapeHtml(line);
  }

  function highlightYAML(text) {
    return text.split("\n").map(highlightYAMLLine).join("\n");
  }

  // Never reformats — only decorates the raw text with color. Re-serializing
  // JSON via JSON.stringify on every render (e.g. after each save) would
  // silently discard blank lines and whitespace the user just typed, which
  // is exactly the kind of surprise a "click to edit and save" view must not do.
  function buildDataDocumentHtml(kind, rawText) {
    if (kind === "json") {
      let bannerHtml = "";

      try {
        JSON.parse(rawText);
      } catch (error) {
        bannerHtml = `<p class="document__error doc-parse-error">Invalid JSON: ${escapeHtml(error.message)}</p>`;
      }

      return `${bannerHtml}<pre class="doc-plain"><code class="doc-plain__code language-json">${highlightJSON(rawText)}</code></pre>`;
    }

    return `<pre class="doc-plain"><code class="doc-plain__code language-yaml">${highlightYAML(rawText)}</code></pre>`;
  }

  // --- Editing & saving ---------------------------------------------------

  const editState = {
    active: false,
    kind: "markdown",
    textareaEl: null,
    pendingKind: null,
    pendingValue: null,
  };

  let toastEl = null;
  let toastHideTimer = 0;

  function showToast(message, tone, autoHideMs) {
    if (!toastEl) {
      toastEl = document.createElement("p");
      toastEl.className = "doc-toast";
      toastEl.setAttribute("aria-live", "polite");
      document.body.appendChild(toastEl);
    }

    toastEl.textContent = message;
    toastEl.dataset.tone = tone || "";
    toastEl.classList.add("doc-toast--visible");

    window.clearTimeout(toastHideTimer);
    if (autoHideMs) {
      toastHideTimer = window.setTimeout(() => {
        toastEl.classList.remove("doc-toast--visible");
      }, autoHideMs);
    }
  }

  function canSaveViaBridge() {
    return !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mdvSaveBridge);
  }

  function sanitizeMarkdown(source) {
    return window.DOMPurify.sanitize(window.marked.parse(source || "", { gfm: true, breaks: true }), {
      USE_PROFILES: { html: true },
      ALLOW_UNKNOWN_PROTOCOLS: false,
      FORBID_TAGS: ["script", "style"],
      FORBID_ATTR: ["style"],
    });
  }

  // Markdown: click into the preview to swap to a raw-source editor. Markdown
  // rendering discards the literal syntax (headings lose their `#`, etc.), so
  // editing the rendered HTML directly could not be saved back losslessly —
  // the raw-source swap is what guarantees the file on disk never gets corrupted.
  function enterEditMode() {
    if (editState.active) return;

    closeFindBar();
    editState.active = true;

    const textarea = document.createElement("textarea");
    textarea.className = "doc-editor";
    textarea.value = renderedRawContent;
    textarea.spellcheck = false;
    textarea.setAttribute("aria-label", "Edit document source — Esc to discard, ⌘S to save");
    textarea.addEventListener("keydown", (event) => {
      if (event.key === "Escape") {
        event.preventDefault();
        exitEditMode();
      } else if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "s") {
        event.preventDefault();
        requestSave("markdown", textarea.value);
      }
    });

    contentEl.innerHTML = "";
    contentEl.appendChild(textarea);
    editState.textareaEl = textarea;

    textarea.focus();
  }

  function exitEditMode() {
    editState.active = false;
    editState.textareaEl = null;
    applyRenderedContent();
  }

  function handleContentClick(event) {
    if (editState.active) return;
    if (event.target.closest("a, button")) return;
    if (window.getSelection().toString().length > 0) return;

    enterEditMode();
  }

  // JSON / YAML: the highlighted view is textually identical to the raw
  // source (spans only decorate, never add or remove characters), so it can
  // be edited directly in place with no separate raw/rendered mode at all.
  // execCommand("insertText") is unreliable for inserting literal characters
  // (e.g. "\n") into a contenteditable in WKWebView — confirmed by hand: it
  // silently drops a bare "\n" — so newline/paste insert a real text node
  // directly via the Selection/Range API instead.
  function insertPlainTextAtCursor(text) {
    const selection = window.getSelection();
    if (!selection || selection.rangeCount === 0) return;

    const range = selection.getRangeAt(0);
    range.deleteContents();

    const node = document.createTextNode(text);
    range.insertNode(node);

    range.setStartAfter(node);
    range.setEndAfter(node);
    selection.removeAllRanges();
    selection.addRange(range);
  }

  function placeCursorAtEnd(element) {
    const range = document.createRange();
    range.selectNodeContents(element);
    range.collapse(false);

    const selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
  }

  // Manual Range edits (above) bypass WKWebView's own edit-command pipeline,
  // so they never reach its native undo manager — confirmed by hand: ⌘Z does
  // not revert them, even though ⌘Z does reach this keydown listener despite
  // the app's Edit-menu key equivalent for Undo. Untracked edits are worse
  // than no undo at all (⌘Z silently doing nothing looks broken), so this
  // surface keeps its own small history instead of relying on the native one.
  function createEditHistory(surface) {
    const past = [];
    const future = [];
    let burstTimer = 0;

    function snapshotIfNewBurst() {
      if (burstTimer === 0) {
        past.push(surface.innerHTML);
        if (past.length > 200) past.shift();
        future.length = 0;
      }
      window.clearTimeout(burstTimer);
      burstTimer = window.setTimeout(() => {
        burstTimer = 0;
      }, 500);
    }

    function restore(fromStack, toStack) {
      if (fromStack.length === 0) return;
      window.clearTimeout(burstTimer);
      burstTimer = 0;
      toStack.push(surface.innerHTML);
      surface.innerHTML = fromStack.pop();
      placeCursorAtEnd(surface);
    }

    return {
      recordBeforeChange: snapshotIfNewBurst,
      undo: () => restore(past, future),
      redo: () => restore(future, past),
    };
  }

  function setupDirectEditableSurface() {
    if (editState.kind !== "json" && editState.kind !== "yaml") return;

    const surface = contentEl.querySelector(".doc-plain");
    if (!surface) return;

    surface.contentEditable = "true";
    surface.spellcheck = false;
    surface.setAttribute("aria-label", "Edit document — Esc to discard, ⌘S to save, ⌘Z to undo");

    const history = createEditHistory(surface);

    surface.addEventListener("beforeinput", () => history.recordBeforeChange());

    surface.addEventListener("keydown", (event) => {
      const meta = event.metaKey || event.ctrlKey;

      if (event.key === "Escape") {
        event.preventDefault();
        surface.blur();
        applyRenderedContent();
      } else if (meta && event.key.toLowerCase() === "s") {
        event.preventDefault();
        requestSave(editState.kind, surface.textContent);
      } else if (meta && event.key.toLowerCase() === "z") {
        event.preventDefault();
        if (event.shiftKey) {
          history.redo();
        } else {
          history.undo();
        }
      } else if (event.key === "Enter") {
        event.preventDefault();
        history.recordBeforeChange();
        insertPlainTextAtCursor("\n");
      }
    });

    surface.addEventListener("paste", (event) => {
      event.preventDefault();
      history.recordBeforeChange();
      const text = (event.clipboardData || window.clipboardData).getData("text/plain");
      insertPlainTextAtCursor(text);
    });
  }

  function requestSave(kind, value) {
    if (kind === "json") {
      try {
        JSON.parse(value);
      } catch (error) {
        showToast(`Invalid JSON — ${error.message}`, "error", 3200);
        return;
      }
    }

    if (!canSaveViaBridge()) {
      showToast("Saving is only available inside the app.", "error", 3200);
      return;
    }

    editState.pendingKind = kind;
    editState.pendingValue = value;
    showToast("Saving…", "", 0);
    window.webkit.messageHandlers.mdvSaveBridge.postMessage({ action: "save", content: value });
  }

  function handleSaveResult(success, message) {
    if (editState.pendingValue === null) return;

    if (!success) {
      showToast(message || "Could not save the file.", "error", 3200);
      return;
    }

    renderedRawContent = editState.pendingValue;
    const kind = editState.pendingKind;
    editState.pendingKind = null;
    editState.pendingValue = null;

    try {
      renderedContentHtml = kind === "markdown" ? sanitizeMarkdown(renderedRawContent) : buildDataDocumentHtml(kind, renderedRawContent);
    } catch (error) {
      console.error(error);
    }

    if (kind === "markdown") {
      exitEditMode();
    } else {
      applyRenderedContent();
    }

    showToast(message || "Saved", "success", 1400);
  }

  window.mdvOnSaveResult = handleSaveResult;

  function initEditing(payload) {
    editState.kind = payload.kind;
    renderedRawContent = payload.content || "";

    if (payload.kind === "markdown") {
      contentEl.addEventListener("click", handleContentClick);
    }
  }

  initTheme();

  if (!payloadEl) {
    setError("Preview data is missing.");
    createToggleButton();
    return;
  }

  if (!window.marked || !window.DOMPurify) {
    setError("Renderer assets failed to load.");
    createToggleButton();
    return;
  }

  let payload;

  try {
    const rawPayload = JSON.parse(payloadEl.textContent || "{}");

    payload = {
      filename: decodeBase64Utf8(rawPayload.filename),
      sourcePath: decodeBase64Utf8(rawPayload.sourcePath),
      baseUrl: decodeBase64Utf8(rawPayload.baseUrl),
      kind: rawPayload.kind === "json" || rawPayload.kind === "yaml" ? rawPayload.kind : "markdown",
      content: decodeBase64Utf8(rawPayload.content),
    };
  } catch (error) {
    console.error(error);
    setError("Preview data could not be decoded.");
    createToggleButton();
    return;
  }

  applyBaseUrl(payload.baseUrl);
  initEditing(payload);

  document.title = payload.filename || document.title;

  renderedDocumentTitle = payload.filename || document.title;

  try {
    if (payload.kind === "json" || payload.kind === "yaml") {
      renderedContentHtml = buildDataDocumentHtml(payload.kind, payload.content || "");
    } else {
      renderedContentHtml = sanitizeMarkdown(payload.content) || "<p></p>";
    }

    applyRenderedContent();

    if (payload.kind === "markdown") {
      const firstHeading = contentEl.querySelector("h1");
      if (firstHeading && firstHeading.textContent.trim()) {
        renderedDocumentTitle = firstHeading.textContent.trim();
        document.title = renderedDocumentTitle;
      }
    }
  } catch (error) {
    console.error(error);
    setError(`${payload.kind === "markdown" ? "Markdown" : payload.kind.toUpperCase()} preview failed to render.`);
  }

  window.mdvOpenFindBar = openFindBar;
  window.mdvToggleFindBar = toggleFindBar;
  window.mdvFindNextMatch = () => jumpToSearchMatch(1);
  window.mdvFindPreviousMatch = () => jumpToSearchMatch(-1);
  window.mdvCloseFindBar = closeFindBar;

  contentEl.addEventListener("click", handleFragmentLinkClick);

  createSearchPanel();
  createToggleButton();
})();
