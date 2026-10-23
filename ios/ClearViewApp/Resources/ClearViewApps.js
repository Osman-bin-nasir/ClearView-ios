(() => {
  'use strict';
  const site = clearViewInitial.site;
  const host = location.hostname;
  const isYouTube = host === 'youtube.com' || host.endsWith('.youtube.com');
  const isInstagram = host === 'instagram.com' || host.endsWith('.instagram.com');
  const isSnapchat = host === 'snapchat.com' || host.endsWith('.snapchat.com');
  const isFacebook = host === 'facebook.com' || host.endsWith('.facebook.com');
  const isGoogle = /^(?:www\.|m\.)?google\.[a-z]{2,}(?:\.[a-z]{2,})?$/.test(host);
  const isService = isYouTube || isInstagram || isSnapchat || isFacebook;
  // All four are presented with ClearView's native header and bottom navigation.
  // Only YouTube and Instagram opt into ClearView's dark palette; Snapchat and
  // Facebook keep their own colours.
  const isAppShell = isService;
  const usesDarkPalette = isYouTube || isInstagram;
  const domain = isYouTube ? 'youtube.com' : isInstagram ? 'instagram.com'
    : isSnapchat ? 'snapchat.com' : isFacebook ? 'facebook.com' : host;
  if (location.protocol !== 'https:') return;
  let config = clearViewInitial;
  // Each app names its vertical feed differently and has its own switch.
  const shortSetting = () => isYouTube ? config.blockShorts
    : isInstagram ? config.blockReels
    : isSnapchat ? config.blockSpotlight
    : isFacebook ? config.blockFacebookReels : false;
  const shortName = () => isYouTube ? 'Shorts' : isSnapchat ? 'Spotlight' : 'Reels';
  let running = false;
  let lastURL = '';
  let timer;
  let sequence = 0;
  let lastPageState = '';
  const documentID = Math.random().toString(36).slice(2) + Date.now().toString(36);
  const tracked = new Map();
  const elementIDs = new WeakMap();
  const home = isYouTube ? 'https://m.youtube.com/' : isInstagram ? 'https://www.instagram.com/'
    : isSnapchat ? 'https://www.snapchat.com/discover' : isFacebook ? 'https://m.facebook.com/' : 'https://www.google.com/';
  const cardSelector = isYouTube
    ? 'ytm-rich-item-renderer,ytm-video-with-context-renderer,ytm-video-renderer,ytm-compact-video-renderer,ytm-grid-video-renderer,ytm-reel-item-renderer,ytm-shorts-lockup-view-model,ytm-shorts-lockup-view-model-v2,yt-shorts-lockup-view-model,ytd-rich-item-renderer,ytd-video-renderer,ytd-compact-video-renderer,ytd-reel-item-renderer,ytm-reel-video-renderer,ytd-reel-video-renderer'
    : '[role="article"],article,[role="listitem"]';
  const send = payload => {
    try { window.webkit.messageHandlers.appsFilter.postMessage(payload); } catch (_) { /* Navigation can detach a frame. */ }
  };
  const shortPath = value => {
    try {
      const url = new URL(value, location.href);
      if (!isService || (url.hostname !== domain && !url.hostname.endsWith('.' + domain))) return false;
      const path = url.pathname.toLowerCase();
      if (isYouTube) return /^\/shorts(?:\/|$)/.test(path);
      if (isInstagram) return /^\/reels?(?:\/|$)/.test(path);
      if (isSnapchat) return /^(?:\/web)?\/spotlight(?:\/|$)/.test(path);
      // Facebook's share sheet produces /share/reel/<id> and /share/r/<id> links.
      return /^\/(?:reels?|share\/reel|share\/r)(?:\/|$)/.test(path);
    } catch (_) { return false; }
  };
  const isAuthenticationPage = () => /^\/(accounts|signin|login|challenge|consent|checkpoint)(?:\/|$)/i.test(location.pathname);
  const text = (element, max = 4500) => {
    if (!element) return '';
    // Never read input values, editable text, cookies, storage or request bodies.
    const snapshot = element.cloneNode(true);
    snapshot.querySelectorAll('form,input,textarea,select,[contenteditable="true"]').forEach(node => node.remove());
    const visible = (snapshot.textContent || '').slice(0, max);
    const labels = Array.from(snapshot.querySelectorAll('img[alt],a[title]')).slice(0, 8)
      .map(node => node.getAttribute('alt') || node.getAttribute('title') || '').join(' ');
    return (visible + ' ' + labels).slice(0, max);
  };
  const pause = element => element.querySelectorAll('video,audio').forEach(media => media.pause());

  const style = document.createElement('style');
  style.id = 'clearview-app-style';
  style.textContent = `
    html { -webkit-tap-highlight-color:rgba(99,218,203,.16); }
    html[data-cv-dark="true"][data-cv-service="true"] { color-scheme:dark; background:#0f1514; }
    html[data-cv-dark="true"][data-cv-service="true"] body { background-color:#0f1514; }
    html[data-cv-dark="true"][data-cv-service="true"] {
      --yt-spec-base-background:#0f1514; --yt-spec-raised-background:#1c2422;
      --yt-spec-menu-background:#1c2422; --yt-spec-text-primary:#f1f5f4;
      --yt-spec-text-secondary:#aebeb9; --yt-spec-brand-background-primary:#0f1514;
      --ig-primary-background:15,21,20; --ig-secondary-background:24,32,30;
      --ig-primary-text:241,245,244; --ig-secondary-text:174,190,185;
      --ig-separator:44,55,52; --ig-elevated-background:28,36,34;
    }
    html[data-cv-remove-blocked="true"] [data-cv-hidden="true"] { display:none!important; }
    html[data-cv-remove-blocked="false"] [data-cv-hidden="true"] { position:relative!important; pointer-events:none!important; }
    html[data-cv-remove-blocked="false"] [data-cv-hidden="true"] > * { visibility:hidden!important; }
    html[data-cv-remove-blocked="false"] [data-cv-hidden="true"]::after {
      content:'Hidden by your protection';position:absolute;inset:0;z-index:1;display:flex;
      align-items:center;justify-content:center;background:#192321;color:#aebeb9;
      font:14px -apple-system,BlinkMacSystemFont,sans-serif;min-height:48px;
    }
    html[data-cv-hide-google-categories="true"] [data-cv-search-category="true"],
    html[data-cv-block-ads="true"] ytm-ad-slot-renderer,
    html[data-cv-block-ads="true"] ytm-promoted-sparkles-web-renderer,
    html[data-cv-block-ads="true"] ytm-promoted-video-renderer,
    html[data-cv-block-ads="true"] ytd-ad-slot-renderer,
    html[data-cv-block-ads="true"] ytd-promoted-sparkles-web-renderer,
    html[data-cv-block-ads="true"] .video-ads,
    html[data-cv-block-ads="true"] .ytp-ad-overlay-container { display:none!important; }
    [data-cv-review="pending"] { visibility:hidden!important; }
    [data-cv-app-prompt="true"] { display:none!important; }
    html[data-cv-app-shell="true"] [data-cv-web-chrome="true"],
    html[data-cv-app-shell="true"] ytm-pivot-bar-renderer,
    html[data-cv-app-shell="true"] ytm-pivot-bar-view-model,
    html[data-cv-app-shell="true"] ytm-mobile-topbar-renderer,
    html[data-cv-app-shell="true"] ytm-mobile-topbar-renderer-v2,
    html[data-cv-app-shell="true"] ytm-feed-filter-chip-bar-renderer,
    html[data-cv-app-shell="true"] .feed-filter-chip-bar,
    html[data-cv-app-shell="true"] ytd-masthead,
    html[data-cv-app-shell="true"] #masthead-container { display:none!important; }
    html[data-cv-app-shell="true"] ytm-app {
      padding-top:0!important;padding-bottom:0!important;margin-top:0!important;
      --ytm-pivot-bar-height:0px;--mobile-topbar-height:0px;
      --default-mobile-topbar-height:0px;--default-ytd-masthead-height:0px;
    }
    html[data-cv-app-shell="true"] ytm-rich-item-renderer { margin-inline:0!important; }
    html[data-cv-app-shell="true"] .media-item-thumbnail-container,
    html[data-cv-app-shell="true"] .video-thumbnail-container { border-radius:0!important; }
    html[data-cv-hide-shorts="true"] [data-cv-short-nav="true"],
    html[data-cv-hide-shorts="true"] [data-cv-short-shelf="true"],
    html[data-cv-hide-shorts="true"] ytm-pivot-bar-item-renderer:has([aria-label="Shorts"]),
    html[data-cv-hide-shorts="true"] a[href^="/shorts"],
    html[data-cv-hide-shorts="true"] a[href^="/reel/"],
    html[data-cv-hide-shorts="true"] a[href^="/reels/"],
    html[data-cv-hide-shorts="true"] a[href^="/spotlight"],
    html[data-cv-hide-shorts="true"] a[href*="/spotlight"],
    html[data-cv-hide-shorts="true"] a[href^="/share/reel/"],
    html[data-cv-hide-shorts="true"] a[href^="/share/r/"] { display:none!important; }
    html[data-cv-hide-shorts="true"] ytm-reel-shelf-renderer,
    html[data-cv-hide-shorts="true"] ytd-reel-shelf-renderer,
    html[data-cv-hide-shorts="true"] ytm-shorts-lockup-view-model,
    html[data-cv-hide-shorts="true"] ytm-shorts-lockup-view-model-v2,
    html[data-cv-hide-shorts="true"] yt-shorts-lockup-view-model,
    html[data-cv-hide-shorts="true"] ytm-reel-item-renderer,
    html[data-cv-hide-shorts="true"] ytd-reel-item-renderer { display:none!important; }
    ytm-app-promo-renderer,ytm-open-app-banner-renderer,ytm-mobile-app-promo-renderer { display:none!important; }
    a[href*="apps.apple.com"],a[href*="itunes.apple.com"],a[href*="play.google.com/store/apps"] { display:none!important; }
    #clearview-route-cover,#clearview-short-route-cover {
      position:fixed;inset:0;z-index:2147483647;background:#0f1514;color:#dde4e3;
      display:flex;flex-direction:column;align-items:center;justify-content:center;
      padding:28px;font:16px -apple-system,BlinkMacSystemFont,sans-serif;text-align:center;
    }
    #clearview-route-cover h2,#clearview-short-route-cover h2 { font-size:24px;line-height:1.3;margin:0 0 12px; }
    #clearview-route-cover p,#clearview-short-route-cover p { color:#aebeb9;max-width:290px;line-height:1.5; }
    #clearview-route-cover a,#clearview-short-route-cover a { display:inline-block;background:#63dacb;color:#003731;
      text-decoration:none;font-weight:600;border-radius:24px;padding:14px 24px;margin-top:16px; }
  `;

  function mount() {
    if (!document.documentElement) return;
    if (!style.isConnected) (document.head || document.documentElement).append(style);
    document.documentElement.dataset.cvDark = String(config.dark);
    document.documentElement.dataset.cvService = String(usesDarkPalette);
    document.documentElement.dataset.cvHideShorts = String(Boolean(shortSetting()));
    document.documentElement.dataset.cvAppShell = String(Boolean(config.appShell) && isAppShell && !isAuthenticationPage());
    document.documentElement.dataset.cvRemoveBlocked = String(config.removeBlockedCards !== false);
    document.documentElement.dataset.cvHideGoogleCategories = String(isGoogle && config.hideGoogleCategories);
    document.documentElement.dataset.cvBlockAds = String(isYouTube && config.blockAds);
  }

  function route() {
    if (lastURL !== location.href) {
      lastURL = location.href;
      detailCover?.remove();
      detailCover = null;
      send({kind:'route'});
      tracked.forEach(value => { value.fingerprint = ''; });
    }
    const blocked = Boolean(shortSetting()) && shortPath(location.href);
    let cover = document.getElementById('clearview-short-route-cover');
    if (blocked) {
      pause(document);
      if (!cover && document.body) {
        cover = document.createElement('div');
        cover.id = 'clearview-short-route-cover';
        cover.setAttribute('role', 'status');
        const heading = document.createElement('h2');
        heading.textContent = shortName() === 'Spotlight' ? 'Spotlight is hidden' : shortName() + ' are hidden';
        const detail = document.createElement('p');
        detail.textContent = 'Your setting keeps short videos out of this app. You can change it with the shield button.';
        const link = document.createElement('a');
        link.href = home;
        link.textContent = 'Back to home';
        cover.append(heading, detail, link);
        document.body.append(cover);
      }
    } else if (cover) cover.remove();
  }

  function markAppChrome() {
    if (!isAppShell || !config.appShell) return;
    const selector = isYouTube
      ? 'ytm-pivot-bar-renderer,ytm-pivot-bar-view-model,ytm-mobile-topbar-renderer,ytm-mobile-topbar-renderer-v2,ytd-masthead,#masthead-container'
      : isSnapchat
        ? 'header,nav,[role="navigation"],[role="banner"],[data-testid="mobile-nav-top"],[class*="MobileNavigation_mobileNavContainer"],[class*="MobileHeader_headerWrapper"],[class*="MobileGhostIconCTABanner"]'
        : isFacebook
          ? 'header,nav,[role="navigation"],[role="banner"],footer,[role="contentinfo"],[data-testid*="banner"],[data-testid*="upsell"]'
          : 'nav,[role="navigation"],[role="banner"],footer,[role="contentinfo"]';
    document.querySelectorAll(selector).forEach(node => {
      if (!node.closest('article,form,[role="dialog"]')) node.setAttribute('data-cv-web-chrome', 'true');
    });
    if (!isYouTube) document.querySelectorAll('header').forEach(node => {
      if (!node.closest('main,article,form,[role="dialog"]')) node.setAttribute('data-cv-web-chrome', 'true');
    });
  }

  /// Snapchat and Facebook put "open the app" / "download the app" prompts in the
  /// middle of their web pages. Those are website chrome, not content: mark them
  /// so the app-shell CSS removes them, including the text-only banners that have
  /// no stable class name.
  function hideAppPrompts() {
    if (!isSnapchat && !isFacebook) return;
    if (!document.body) return;
    document.querySelectorAll('[data-cv-app-prompt="true"]').forEach(node => node.removeAttribute('data-cv-app-prompt'));
    let selector = 'a[href*="apps.apple.com"],a[href*="itunes.apple.com"],a[href*="play.google.com/store/apps"],a[href^="snapchat://"],a[href^="fb://"]';
    if (isSnapchat) {
      selector += ',a[href*="click.snapchat.com"],a[href*="link.snapchat.com"],a[href*="snapchat.com/download"],'
        + '[class*="MobileGhostIconCTABanner"],[class*="MobileHeader_headerWrapper"],[class*="MobileHeader_mobileInstallButton"],'
        + '[class*="HomepageContent_mobileDownloadSnapchat"],[class*="HomepageContent_landingScreen"],'
        + '[class*="HomepageContent_heroContent"],[data-testid="ConsumerNav_DownloadButton"]';
    }
    document.querySelectorAll(selector).forEach(node => node.setAttribute('data-cv-app-prompt', 'true'));
    const patterns = isSnapchat
      ? [/^open snapchat$/i, /^install$/i, /^download$/i, /^download snapchat$/i,
         /^download to try the most popular/i, /^open in app$/i,
         /^snapchat is better on the app$/i, /^snapchat app$/i, /^open in snapchat$/i,
         /^browser continue$/i]
      : [/^get facebook for ios and browse faster\.?$/i, /^open in app$/i];
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    let node;
    while ((node = walker.nextNode())) {
      const value = (node.textContent || '').trim();
      if (!value || value.length > 140 || !patterns.some(pattern => pattern.test(value))) continue;
      let element = node.parentElement;
      for (let depth = 0; element && depth < 5; depth++, element = element.parentElement) {
        const tag = element.tagName.toLowerCase();
        if (tag === 'a' || tag === 'button' || element.getAttribute('role') === 'button' || tag === 'header') {
          element.setAttribute('data-cv-app-prompt', 'true');
          break;
        }
        if (depth >= 2 && element.textContent.trim().length <= 200) {
          element.setAttribute('data-cv-app-prompt', 'true');
          break;
        }
      }
    }
    if (isFacebook) {
      // The login page's footer is plain links with no landmark role. Remove the
      // "Meta / About Help More" strip so the app navigation is the last bar.
      document.querySelectorAll('div,section,footer').forEach(element => {
        const value = (element.textContent || '').replace(/\s+/g, ' ').trim();
        if (value.length <= 40 && value.endsWith('About Help More') && !element.querySelector('input,form')) {
          element.setAttribute('data-cv-app-prompt', 'true');
        }
        const labels = Array.from(element.children)
          .map(child => (child.textContent || '').replace(/\s+/g, ' ').trim().toLowerCase())
          .filter(Boolean);
        if (labels.filter(label => ['about', 'help', 'more'].includes(label)).length >= 2) {
          element.setAttribute('data-cv-app-prompt', 'true');
        }
      });
    }
  }

  function shortControl(element) {
    const href = element.getAttribute('href') || element.getAttribute('data-href');
    if (href && shortPath(href)) return true;
    const label = element.getAttribute('aria-label') || element.getAttribute('title') || '';
    if (/^(?:shorts|reels|spotlight)(?:\s|$)/i.test(label.trim())) return true;
    const tab = element.getAttribute('tab-identifier') || element.getAttribute('data-tab-identifier') || '';
    if (/(?:shorts|reels|spotlight)/i.test(tab)) return true;
    return /^(?:shorts|reels|spotlight)$/i.test((element.textContent || '').trim());
  }

  function hideShortLinks() {
    if (!isService) return;
    // Navigation is not necessarily an anchor: YouTube's pivot items often
    // contain buttons and Instagram also uses role=button controls.
    document.querySelectorAll('[data-cv-short-nav]').forEach(node => node.removeAttribute('data-cv-short-nav'));
    document.querySelectorAll('[data-cv-short-shelf]').forEach(node => node.removeAttribute('data-cv-short-shelf'));
    const selector = 'a[href],button[aria-label],button[title],[role="button"][aria-label],[role="link"],[role="tab"],ytm-pivot-bar-item-renderer,ytm-pivot-bar-item-view-model,[tab-identifier],[data-tab-identifier]';
    document.querySelectorAll(selector).forEach(element => {
      if (!shortControl(element)) return;
      const item = element.closest('ytm-pivot-bar-item-renderer,ytm-pivot-bar-item-view-model,[role="tab"],[role="menuitem"]');
      (item || element).setAttribute('data-cv-short-nav', 'true');
    });
    if (isYouTube) {
      // Newer shelves can use a rich-section wrapper instead of reel-shelf.
      // Remove the whole shelf, including its heading and layout space.
      const shelves = 'ytm-reel-shelf-renderer,ytm-shorts-shelf-renderer,ytm-rich-section-renderer,ytm-shelf-renderer,ytd-reel-shelf-renderer,ytd-rich-section-renderer';
      document.querySelectorAll('h2,h3,[role="heading"],ytm-shelf-header-renderer').forEach(heading => {
        if (!/^shorts$/i.test((heading.textContent || '').trim()) && !heading.querySelector('[aria-label="Shorts"]')) return;
        let section = heading.closest(shelves);
        if (!section) {
          let node = heading.parentElement;
          for (let depth = 0; node && depth < 5; depth++, node = node.parentElement) {
            if (node.matches('main,body,ytm-app,ytm-browse,[role="main"]') || node.querySelector('a[href*="/watch?"]')) break;
            section = node;
          }
        }
        if (section) section.setAttribute('data-cv-short-shelf', 'true');
      });
      document.querySelectorAll(shelves).forEach(section => {
        const hasShorts = section.querySelector('a[href^="/shorts"],ytm-shorts-lockup-view-model,ytm-shorts-lockup-view-model-v2,yt-shorts-lockup-view-model');
        if (hasShorts && !section.querySelector('a[href*="/watch?"]')) section.setAttribute('data-cv-short-shelf', 'true');
      });
    }
  }

  function filterGoogleCategories() {
    if (!isGoogle) return;
    // Mark category controls, not result links or search inputs. Marking is
    // reversible so disabling the preference restores existing categories.
    document.querySelectorAll('[data-cv-search-category]').forEach(node => node.removeAttribute('data-cv-search-category'));
    document.querySelectorAll('[role="navigation"] a,[role="navigation"] [role="button"],[role="tablist"] a,[role="tab"],#hdtb a,#hdtb button,#hdtb [role="button"],header a,header button').forEach(node => {
      const label = (node.getAttribute('aria-label') || node.textContent || '').trim();
      if (/^All$/i.test(label)) return;
      const anchor = node.closest('a[href]') || node.querySelector('a[href]');
      let category = false;
      try {
        const url = new URL(anchor?.href || '', location.href);
        category = url.hostname === host && url.pathname === '/search' && (url.searchParams.has('tbm') || url.searchParams.has('udm'));
      } catch (_) { /* Not a category URL. */ }
      if (category || /^(?:Images|Videos|Short videos|News|Shopping|Maps|Books|Flights|Finance|Forums|Web|AI Mode|More|Search tools|Tools)$/i.test(label)) {
        (node.closest('[role="tab"]') || node).setAttribute('data-cv-search-category', 'true');
      }
    });
    document.querySelectorAll('a,button,span,[role="button"]').forEach(node => {
      const label = (node.textContent || '').trim();
      if (/^(?:Search tools|Feedback)$/i.test(label) && !node.closest('#rso,article')) {
        (node.closest('a,button,[role="button"]') || node).setAttribute('data-cv-search-category', 'true');
      }
    });
    // Mobile category chips can live outside navigation landmarks.
    document.querySelectorAll('a[href*="tbm="],a[href*="udm="]').forEach(anchor => {
      if (anchor.closest('main,#search,#rso,article') || anchor.querySelector('h3')) return;
      const label = (anchor.textContent || '').trim();
      if (label && label.length < 35 && !/^All$/i.test(label)) anchor.setAttribute('data-cv-search-category', 'true');
    });
  }

  function skipVideoAds() {
    if (!isYouTube || !config.blockAds || !running) return;
    const player = document.querySelector('.html5-video-player.ad-showing,.html5-video-player.ad-interrupting,#movie_player.ad-showing');
    if (!player) return;
    const skip = player.querySelector('.ytp-ad-skip-button,.ytp-ad-skip-button-modern,.ytp-skip-ad-button,button[class*="ad-skip"]');
    if (skip) skip.click();
    const video = player.querySelector('video');
    if (video && Number.isFinite(video.duration) && video.duration > 0 && video.currentTime < video.duration - 0.05) {
      try { video.currentTime = video.duration; } catch (_) { /* Non-seekable ads may still offer Skip. */ }
    }
  }

  function describe(element, detail = false) {
    const links = Array.from(element.querySelectorAll('a[href]'));
    if (element.matches('a[href]')) links.unshift(element);
    const link = links.find(anchor => {
      const href = anchor.getAttribute('href') || '';
      if (isYouTube) return /\/(watch|shorts|live)(?:[/?]|$)/.test(href);
      if (isInstagram) return /\/(p|reels?)\//.test(href);
      if (isSnapchat) return /^\/spotlight\//.test(href) || /^\/@/.test(href);
      if (isFacebook) return /\/(?:reel|reels|videos?|watch|stories?)\//.test(href);
      return true;
    });
    const creatorLink = links.find(anchor => {
      const href = anchor.getAttribute('href') || '';
      if (isYouTube) return /\/(?:@|channel\/|c\/)/.test(href);
      if (isInstagram) return /^\/[a-zA-Z0-9_.]+\/?$/.test(href);
      if (isSnapchat) return /^\/@[a-zA-Z0-9_.-]+\/?$/.test(href);
      if (isFacebook) return /^\/[a-zA-Z0-9.]+\/?$/.test(href)
        && !/^\/(?:reel|reels|watch|share|stories|login|signup)\/?$/i.test(href);
      return true;
    });
    const href = detail ? location.href : link?.href || '';
    const title = detail && isYouTube
      ? text(document.querySelector('ytm-slim-video-metadata-renderer,ytm-watch-metadata,ytm-video-description-header-renderer,#above-the-fold'), 4500) || document.title
      : text(element);
    return {text:title, creator:creatorLink?.textContent?.trim().slice(0, 200) || '', url:href,
      short:shortPath(href) || /reel|shorts|spotlight/.test(element.tagName.toLowerCase()), detail};
  }

  function queue(element, description, items) {
    if (!description.text.trim() && !description.creator) return;
    let id = elementIDs.get(element);
    if (!id) { id = 'cv' + (++sequence); elementIDs.set(element, id); }
    const fingerprint = JSON.stringify(description);
    const previous = tracked.get(id);
    if (previous?.fingerprint === fingerprint) return;
    const revision = (previous?.revision || 0) + 1;
    tracked.set(id, {element, fingerprint, description, revision});
    // Feed cards stay concealed until the native matcher returns a verdict.
    if (!description.detail) element.setAttribute('data-cv-review', 'pending');
    items.push({id, revision, text:description.text, creator:description.creator, url:description.url, short:description.short});
  }

  function scan() {
    timer = undefined;
    if (!running || !document.body) return;
    mount();
    route();
    markAppChrome();
    hideAppPrompts();
    hideShortLinks();
    filterGoogleCategories();
    skipVideoAds();
    if (isAuthenticationPage() || ['accounts.google.com','consent.google.com','myaccount.google.com'].includes(host)) return;
    const emptyHome = isYouTube && location.pathname === '/' && /Try searching to get started/i.test(document.body.textContent || '');
    const pageState = location.href + ':' + emptyHome;
    if (pageState !== lastPageState) {
      lastPageState = pageState;
      send({kind:'pageState', url:location.href, emptyHome});
    }
    const items = [];
    // Page-level matching excludes recommendations, comments, menus and login forms.
    if (isYouTube && /^\/(watch|shorts|live)(?:[/?]|$)/.test(location.pathname)) {
      const metadata = document.querySelector('ytm-slim-video-metadata-renderer,ytm-watch-metadata,ytm-video-description-header-renderer,#above-the-fold');
      if (metadata || document.title) queue(document.body, describe(metadata || document.body, true), items);
    }
    if (!isService && document.title) queue(document.body, {text:document.title.slice(0, 4500),creator:'',url:location.href,short:false,detail:true}, items);
    const cards = Array.from(document.querySelectorAll(cardSelector));
    if (isGoogle && location.pathname === '/search') {
      document.querySelectorAll('a h3').forEach(heading => {
        const anchor = heading.closest('a');
        let card = anchor;
        let parent = anchor?.parentElement;
        for (let depth = 0; parent && depth < 6; depth++, parent = parent.parentElement) {
          if (parent.matches('main,body,#main,#search,#rso') || parent.querySelectorAll('a h3').length > 1) break;
          if (parent.matches('.g,.MjjYud,.tF2Cxc,[data-sokoban-container]')) card = parent;
        }
        if (card && !card.closest('form,[role="dialog"]') && !cards.includes(card)) cards.push(card);
      });
    }
    // Instagram Explore uses grid links instead of articles. Find the image-bearing
    // tile, not its surrounding grid, so one match cannot hide an entire profile.
    if (isInstagram) {
      document.querySelectorAll('a[href^="/p/"],a[href^="/reel/"],a[href^="/reels/"]').forEach(anchor => {
        if (!anchor.closest('article,[role="listitem"]') && anchor.querySelector('img,video')) cards.push(anchor);
      });
      // The full-screen Reels viewer does not always use article/listitem. Pick
      // the nearest caption-bearing container for each video, stopping before
      // a parent that contains another reel. Never match the entire reel feed.
      if (shortPath(location.href)) document.querySelectorAll('video').forEach(video => {
        if (video.closest('article,[role="listitem"]')) return;
        let container = video.parentElement;
        let candidate = null;
        for (let depth = 0; container && depth < 10 && container !== document.body; depth++, container = container.parentElement) {
          if (container.querySelectorAll('video').length > 1) break;
          if (container.querySelector('a[href]') && text(container, 500).trim()) { candidate = container; break; }
        }
        if (candidate) cards.push(candidate);
      });
    }
    const shelfContainer = element => !/reel-item|shorts-lockup/.test(element.tagName.toLowerCase())
      && element.querySelector('ytm-reel-shelf-renderer,ytd-reel-shelf-renderer,ytm-shorts-lockup-view-model,ytm-shorts-lockup-view-model-v2,yt-shorts-lockup-view-model');
    for (const card of cards) {
      if (items.length >= 80) break;
      if (isYouTube && shelfContainer(card)) continue;
      const parentCard = card.parentElement?.closest(cardSelector);
      if (parentCard && !(isYouTube && shelfContainer(parentCard))) continue;
      if (card.closest('form,[role="dialog"],[contenteditable="true"]')) continue;
      const rect = card.getBoundingClientRect();
      if (!card.hasAttribute('data-cv-hidden') && (rect.top > innerHeight * 3 || rect.bottom < -innerHeight)) continue;
      const description = describe(card);
      if (isInstagram && shortPath(location.href) && card.querySelector('video')) description.short = true;
      queue(card, description, items);
    }
    for (const [id, entry] of tracked) {
      if (!entry.element.isConnected) tracked.delete(id);
    }
    if (items.length) send({kind:'scan', document:documentID, items});
  }

  function schedule() {
    if (running && !timer) timer = setTimeout(scan, 180);
  }

  let detailCover = null;
  function resolve(items, documentToken) {
    if (documentToken !== documentID) return;
    for (const item of items) {
      const entry = tracked.get(item.id);
      if (!entry?.element.isConnected || entry.revision !== item.revision) continue;
      const element = entry.element;
      element.removeAttribute('data-cv-review');
      if (entry.description.detail) {
        if (entry.description.url !== location.href) continue;
        detailCover?.remove();
        detailCover = null;
        if (item.blocked) {
          pause(document);
          detailCover = document.createElement('div');
          detailCover.id = 'clearview-route-cover';
          detailCover.setAttribute('role', 'alertdialog');
          detailCover.setAttribute('aria-modal', 'true');
          detailCover.setAttribute('aria-label', 'Hidden by your filters');
          detailCover.tabIndex = -1;
          const heading = document.createElement('h2');
          heading.textContent = 'Hidden by your filters';
          const detail = document.createElement('p');
          detail.textContent = 'This video matches a blocked keyword or creator. Your next watch can be a better one.';
          const link = document.createElement('a');
          link.href = home; link.textContent = 'Back to home';
          detailCover.append(heading, detail, link);
          document.body.append(detailCover);
          detailCover.focus({preventScroll:true});
        }
      } else {
        if (item.blocked) { element.setAttribute('data-cv-hidden', 'true'); pause(element); }
        else element.removeAttribute('data-cv-hidden');
      }
    }
    schedule(); // Continues a feed that required more than one bounded batch.
  }

  const observer = new MutationObserver(schedule);
  function start() {
    if (!document.documentElement) return;
    mount();
    observer.observe(document.documentElement, {subtree:true,childList:true,characterData:true,
      attributes:true,attributeFilter:['href','title','aria-label','alt']});
    send({kind:'ready'});
    schedule();
  }

  window.__clearviewApps = {
    update(next) {
      config = next;
      running = Boolean(next.active);
      tracked.forEach(entry => { entry.fingerprint = ''; });
      if (!running) pause(document);
      mount();
      route();
      markAppChrome();
      hideAppPrompts();
      hideShortLinks();
      filterGoogleCategories();
      skipVideoAds();
      schedule();
    },
    resolve,
    openProfile() {
      const direct = document.querySelector('nav [aria-label="Profile"],[role="navigation"] [aria-label="Profile"],[data-cv-web-chrome] [aria-label="Profile"]');
      const control = direct?.closest('a,button,[role="button"]');
      if (control) { control.click(); return true; }
      const links = Array.from(document.querySelectorAll('nav a[href],[role="navigation"] a[href],[data-cv-web-chrome] a[href]'));
      const profile = links.find(anchor => /^\/(?!accounts\/?$|explore\/?$|reels?\/?$|direct\/?$)[a-zA-Z0-9_.]+\/?$/.test(anchor.getAttribute('href') || '')
        && anchor.querySelector('img'));
      if (profile) { profile.click(); return true; }
      return false;
    },
    search() {
      const selectors = isYouTube
        ? 'button[aria-label="Search"],button[aria-label="Search YouTube"],ytm-topbar-menu-button-renderer .search-button,button.icon-button[aria-label="Search"]'
        : 'a[href="/explore/search/"],svg[aria-label="Search"]';
      let button = document.querySelector(selectors);
      if (button?.tagName.toLowerCase() === 'svg') button = button.closest('a,button,[role="button"]');
      if (!button) return false;
      button.click();
      setTimeout(() => document.querySelector('input[type="search"],input[name="search_query"],input[placeholder*="Search"]')?.focus(), 250);
      return true;
    },
    pause() {
      running = false;
      clearTimeout(timer); timer = undefined;
      pause(document);
    }
  };
  document.addEventListener('click', event => {
    const anchor = event.target.closest?.('a[href]');
    const control = event.target.closest?.('button,[role="button"],[role="tab"],ytm-pivot-bar-item-renderer,ytm-pivot-bar-item-view-model');
    const blocksShorts = Boolean(shortSetting());
    if (blocksShorts && ((anchor && shortPath(anchor.href)) || (control && shortControl(control)))) {
      event.preventDefault(); event.stopImmediatePropagation();
    }
  }, true);
  document.addEventListener('click', event => {
    if (!running || !event.isTrusted || isAuthenticationPage()) return;
    const target = event.target instanceof Element ? event.target : null;
    if (!target || target.closest('a,button,input,textarea,select,label,summary,video,audio,iframe,canvas,[role="button"],[role="tab"],[role="link"],[role="dialog"],[role="alertdialog"],[contenteditable="true"],[data-cv-hidden]')) return;
    if (window.getSelection()?.toString()) return;
    // Text, feed cards and player surfaces are not whitespace.
    if (target.closest('article,[role="listitem"],ytm-rich-item-renderer,ytm-video-with-context-renderer,.html5-video-player')) return;
    if (Array.from(target.childNodes).some(node => node.nodeType === Node.TEXT_NODE && node.textContent.trim())) return;
    send({kind:'whitespaceTap', url:location.href});
  }, true);
  document.addEventListener('play', event => {
    if (!running || (shortSetting() && shortPath(location.href)) || detailCover?.isConnected
        || event.target.closest?.('[data-cv-hidden="true"],[data-cv-review="pending"]')) event.target.pause?.();
  }, true);
  document.addEventListener('visibilitychange', () => { if (document.hidden) pause(document); });
  window.addEventListener('scroll', schedule, {passive:true});
  window.addEventListener('popstate', schedule);
  // SPA history updates happen in the site's own world. Observe its resulting URL,
  // rather than replacing history methods used by login or the site's router.
  setInterval(() => { if (running) { route(); skipVideoAds(); schedule(); } }, 800);
  // Install structural CSS before the first paint, rather than waiting for the
  // whole page to load and briefly showing a second header/bottom bar.
  if (document.documentElement) mount();
  else {
    const bootstrapObserver = new MutationObserver(() => {
      if (document.documentElement) { mount(); bootstrapObserver.disconnect(); }
    });
    bootstrapObserver.observe(document, {childList:true});
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, {once:true});
  else start();
})();
