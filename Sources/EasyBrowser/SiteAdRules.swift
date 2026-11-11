import Foundation

/// Правила против рекламы, которую сайты отдают со своих же доменов: Яндекс (Поиск, Карты,
/// Маркет, Музыка…), поиск Google и YouTube. Обычный список рекламных сетей здесь бессилен,
/// потому что реклама приходит как «свой» ресурс (yabs.yandex.ru на yandex.ru, ролики с
/// googlevideo.com на YouTube).
///
/// Источники: AdGuard Russian filter (раздел «Yandex»), RU AdList, uBlock Origin filters.
/// Правила переведены в формат WebKit Content Blocker: процедурные фильтры (`:upward`,
/// `:style`, `:matches-attr`) и скриптлеты заменены на `pageScript`.
enum SiteAdRules {
    // MARK: - Домены

    /// Домены Яндекса для `if-domain` («*» — домен вместе с поддоменами).
    static let yandexDomains = [
        "*ya.ru", "*yandex.ru", "*yandex.by", "*yandex.kz", "*yandex.uz", "*yandex.com",
        "*yandex.com.tr", "*yandex.com.am", "*yandex.com.ge", "*yandex.az", "*yandex.fr"
    ]

    static let googleDomains = [
        "*google.com", "*google.ru", "*google.by", "*google.kz", "*google.com.ua", "*google.de",
        "*google.co.uk", "*google.fr", "*google.es", "*google.it", "*google.pl", "*google.ca",
        "*google.com.tr", "*google.nl", "*google.com.br", "*google.co.in"
    ]

    static let youTubeDomains = ["*youtube.com", "*youtube-nocookie.com"]

    // MARK: - Сетевые правила

    private struct NetworkRule {
        let filter: String
        var thirdPartyOnly = false
        var ifDomain: [String]? = nil
        var resourceTypes: [String]? = nil
    }

    /// `([^/:]+\.)?` — любой поддомен; `[a-z.]+` — любая доменная зона Яндекса/Google.
    private static let yandexNetworkRules: [NetworkRule] = [
        // Рекламные серверы Яндекса: блокируем всегда, в том числе на самом Яндексе.
        NetworkRule(filter: #"^https?://([^/:]+\.)?an\.yandex\.[a-z.]+[:/]"#),
        NetworkRule(filter: #"^https?://([^/:]+\.)?yabs\.yandex\.[a-z.]+[:/]"#),
        NetworkRule(filter: #"^https?://([^/:]+\.)?awaps\.yandex\.[a-z.]+[:/]"#),
        NetworkRule(filter: #"^https?://([^/:]+\.)?kiks\.yandex\.[a-z.]+[:/]"#),
        NetworkRule(filter: #"^https?://bs\.yandex\.[a-z.]+/"#, resourceTypes: ["script"]),
        NetworkRule(filter: #"^https?://bs-meta\.yandex\.[a-z.]+/"#, resourceTypes: ["script", "raw"]),
        NetworkRule(filter: #"^https?://([^/:]+\.)?yandexadexchange\.net[:/]"#),
        // В url-filter WebKit нет «|», поэтому варианты — отдельными правилами.
        NetworkRule(filter: #"^https?://banners\.adfox\.ru/"#),
        NetworkRule(filter: #"^https?://banners\.adfox\.net/"#),
        NetworkRule(filter: #"^https?://content\.adfox\.ru/"#),
        NetworkRule(filter: #"^https?://([^/:]+\.)?mds\.yandex\.net/get-bstor/"#),
        // Загрузчики РСЯ и Adfox, которые Яндекс отдаёт с yandex.ru/ads/… и yandex.ru/an/…
        NetworkRule(filter: #"^https?://([^/:]+\.)?yandex\.[a-z.]+/ads/system/"#),
        NetworkRule(filter: #"^https?://([^/:]+\.)?yandex\.[a-z.]+/ads/meta/"#),
        NetworkRule(filter: #"^https?://([^/:]+\.)?yandex\.[a-z.]+/ads/adfox/"#),
        NetworkRule(filter: #"^https?://([^/:]+\.)?yandex\.[a-z.]+/an/count/"#),
        NetworkRule(filter: #"^https?://([^/:]+\.)?yandex\.[a-z.]+/an/meta/"#),
        NetworkRule(filter: #"^https?://([^/:]+\.)?yandex\.[a-z.]+/ads/"#, thirdPartyOnly: true),
        NetworkRule(filter: #"^https?://([^/:]+\.)?yandex\.[a-z.]+/an/"#, thirdPartyOnly: true),
        NetworkRule(filter: #"^https?://([^/:]+\.)?ya\.ru/ads/"#, thirdPartyOnly: true),
        NetworkRule(filter: #"^https?://([^/:]+\.)?yandex\.ru/portal/ntp/banner"#),
        // Советник Маркета, который встраивается в чужие магазины.
        NetworkRule(filter: #"^https?://sovetnik\.market\.yandex\.ru/"#, thirdPartyOnly: true),
        NetworkRule(filter: #"^https?://sovetnik\.yandex\.net/"#, thirdPartyOnly: true),
        // Аудио- и видеореклама Музыки и Кинопоиска.
        NetworkRule(filter: #"^https?://storage\.mds\.yandex\.net/get-music/.*/ad-exp/"#),
        NetworkRule(filter: #"/public/prerolls/.*\.mp3"#, ifDomain: ["*music.yandex.ru", "*music.yandex.com"]),
        NetworkRule(filter: #"^https?://strm\.yandex\.[a-z.]+/vh-adfo"#)
    ]

    private static let googleNetworkRules: [NetworkRule] = [
        // Google: проверка качества трафика AdSense и рекламные пути на google.*
        NetworkRule(filter: #"^https?://([^/:]+\.)?adtrafficquality\.google[:/]"#),
        NetworkRule(filter: #"^https?://([^/:]+\.)?google\.[a-z.]+/pagead/"#, thirdPartyOnly: true),
        NetworkRule(filter: #"^https?://([^/:]+\.)?google\.[a-z.]+/adsense/"#, thirdPartyOnly: true),
        NetworkRule(filter: #"^https?://([^/:]+\.)?googleads\.g\.doubleclick\.net[:/]"#),
        NetworkRule(filter: #"^https?://([^/:]+\.)?pagead2\.googlesyndication\.com[:/]"#),

        // YouTube: рекламная статистика и запросы рекламных вставок. Сами ролики
        // рекламы приходят с googlevideo.com, их убирает pageScript.
        NetworkRule(filter: #"^https?://([^/:]+\.)?youtube\.com/pagead/"#),
        NetworkRule(filter: #"^https?://([^/:]+\.)?youtube\.com/api/stats/ads"#),
        NetworkRule(filter: #"^https?://([^/:]+\.)?youtube\.com/get_midroll_"#),
        NetworkRule(filter: #"^https?://([^/:]+\.)?youtube\.com/pcs/activeview"#),
        NetworkRule(filter: #"^https?://([^/:]+\.)?doubleclick\.net/"#, ifDomain: youTubeDomains)
    ]

    // MARK: - Скрытие элементов

    private struct CosmeticRule {
        let domains: [String]?
        /// Начало пути, например "/maps" (`:matches-path` в AdGuard).
        let path: String?
        let selectors: [String]
    }

    private static let yandexCosmeticRules: [CosmeticRule] = [
        // Блоки РСЯ и Adfox на любых сайтах.
        CosmeticRule(domains: nil, path: nil, selectors: [
            "div[id^=\"yandex_rtb\"]", "div[class^=\"yandex_rtb\"]", "div[id^=\"adfox_\"]",
            "div[id^=\"AdFox_banner_\"]", ".ya-partner", ".ya-direct", ".yandex-rtb", ".yandex-rtb-block",
            ".adfox_placeholder", "#yandex_ad", "#yandex_ad2", "a[href*=\"//an.yandex.ru/count/\"]",
            "a[href*=\"//yandex.ru/an/count/\"]", "iframe[src*=\"an.yandex.ru\"]",
            "iframe[src*=\"yandexadexchange.net\"]"
        ]),

        // Яндекс: главная, Поиск, подсказки.
        CosmeticRule(domains: yandexDomains, path: nil, selectors: [
            ".main__top > div.main__carousel",
            "div[id^=\"search-\"] div[style=\"width:240px\"]",
            "#search-result-aside div[style=\"width:240px\"]",
            ".SerpListFeature div.Skeleton_type_ad_search", ".Skeleton_type_ad_search",
            ".DirectFeature", ".DirectInline", ".DirectStripe", ".DirectLine", ".RsyaOrganic",
            "div[class^=\"main-home-\"] > div[style^=\"--image-aspect-ratio:\"]",
            ".services-feed > div[style^=\"--height-ratio:\"]", ".services-feed_banner_yes", ".main-home-banner",
            "ul[class^=\"mini-suggest__\"] > li[data-type=\"nav\"]",
            ".mini-suggest__popup > ul > li[data-suggest-counter] > a[target=\"_blank\"]",
            ".mini-suggest__popup-content > li > a[target=\"_blank\"]",
            "div[id^=\"suggest-item\"] > a[href*=\"//yabs.\"][href*=\"/count/\"]",
            "div[id^=\"suggest-item\"] > a[href^=\"http://yandex\"][href*=\"/clck/\"]",
            "#search-result-aside div[id^=\"Adv_media__\"]",
            "#search-result-aside > div[class*=\"_right_yes\"] > div[data-cid] div[data-vnl*=\"R-I-\"]",
            ".layout__banner", ".WebBanner", ".advert", "div[class*=\"-R-A-\"]",
            ".FuturisAdvTransactionSnippet", ".MessageBubble-Container_component_futurisAdOnly",
            // Картинки
            ".MMSidebar-Card_bottomAdv", ".ImagesViewer-SidebarAdv", ".serp-list > div.incut",
            // Карты
            ".map-controls__additional-button > a[style*=\"--promo-button-\"]",
            ".search-list-view__advert-offer-banner",
            ".search-list-view__list a[href^=\"https://yabs.yandex.ru/count/\"]",
            ".banner-placeholder-view", "._advert", ".search-advert-badge",
            ".card-header-media-view__list > div.card-header-media-view__advert-wrap",
            ".business-card-title-view__actions > div.business-card-title-view__advert",
            ".business-card-title-view__actions > div.business-card-title-view__advert + div.business-card-title-view__call-to-action",
            ".maillist-form-view",
            // Маркет
            "div[data-apiary-widget-name=\"@monetize/MainShowcase\"]",
            "div[data-apiary-widget-name=\"@monetize/HeroContentCarousel\"]",
            "div[data-apiary-widget-name=\"@monetize/HeroSlideshow\"]",
            "div[data-zone-name=\"heroBannerCarousel\"]",
            "div[data-apiary-widget-name=\"@marketfront/RecomAdv\"]",
            "div[data-apiary-widget-name=\"@monetize/AdvStreamer\"]",
            "div[data-apiary-widget-name^=\"@monetize/HeroBannerCarousel\"]",
            "div[data-apiary-widget-name^=\"@monetize/UrbanAds\"]",
            "div[data-apiary-widget-name=\"@monetize/CreativeBanner\"]",
            "div[data-apiary-widget-name=\"@monetize/MadvHeaderPromoStreamer\"]",
            "div[data-apiary-widget-name=\"@marketfront/CreativeBanner\"]",
            "div[data-apiary-widget-name=\"@monetize/RecomMediaAdv\"]", "#banner-streamer",
            // Афиша, Музыка, Диск, Почта, Расписания, Недвижимость, Переводчик, Турбо
            ".adfox", ".adfox_type_branding",
            "section[class^=\"SideAdvertBanner_root__\"]", ".audio-advert__block",
            ".top-direct-line", ".direct-public__right-direct-wrapper",
            ".ComposeDoneScreen-Ads", "div[class*=\"disableAdsContainer\"]",
            ".PartnerPromoHeaderLogo", ".TariffsList__segmentPartnerPromo", ".ThreadLayout__topDirect",
            ".SearchSegmentsDirect", ".Personal__vtbPromoBadge",
            ".RealtyListing-AdfoxBanner", ".AdvPremium-List", ".RealtyListing-AdvItem_listingType_offer",
            ".NewbuildingsPromo", "#sidebar-direct",
            ".unit_rect[data-log-node] > div[class*=\"_type_partner \"]",
            "body[data-bem*=\"turbo\"] div.turbo-advert", "body[data-bem*=\"turbo\"] div[data-name=\"advert\"]"
        ]),
        // Селекторы с :has() — отдельно, чтобы их было легко отключить по одному.
        CosmeticRule(domains: yandexDomains, path: nil, selectors: [
            "ul[id] > li[class*=\"Organic\"]:has(> div.Root div[class*=\"-HeaderAd\"] > span)",
            ".content__left li.serp-item:not(.serp-item__futuris-snippet):has(> div[class] div.AdvLabel)",
            "#search-result > li:has(> div.Bno_isPromoSnippet)",
            "#search-result > [class]:has(> div.Organic > div a[href*=\"_crpd\"])",
            "aside[aria-label=\"Блоки информации\"] + div[class*=\"-\"]:has(> div > div[class*=\"content\"] > div[class*=\"_state_\"] > button[aria-label=\"Действия с рекламой\"])",
            ".i-mini-bem:has(> div[data-hydration-id] > div > div.direct-close-block)",
            ".i-mini-bem:has(> div[data-hydration-id] > div > div[class*=\"-tgo__content\"] > div[class] > span[class*=\"-tgo__mark\"])",
            ".RealtySnippetCard:has(div.RealtyAdv-ContentWrapper)",
            ".unit_rect[data-log-node]:has(> div[class*=\"_type_partner \"])",
            "div[class^=\"layout__top\"] > div[class^=\"layout_\"]:has(> div[style] > div[id^=\"R-I-\"])",
            ".business-card-view__section:has(> div > .business-advert-offer-banner-view)",
            ".grid-chunk > div.grid-chunk__column-box:has(> div.grid-chunk__adv-column)"
        ]),
        CosmeticRule(domains: yandexDomains, path: "/search", selectors: [".AdvMedia"]),
        CosmeticRule(domains: yandexDomains, path: "/maps", selectors: [
            ".banner-view", "div[class^=\"business\"][class*=\"advert-\"]", ".promo-button",
            "div[data-chunk=\"promo-chunk\"]"
        ]),
        CosmeticRule(domains: yandexDomains, path: "/video", selectors: [
            "div[class*=\"-Direct_\"]", "div[class*=\"_placement_video-list\"]"
        ]),
        CosmeticRule(domains: ["*kinopoisk.ru"], path: nil, selectors: [
            ".underheader-superbanner-wrapper", "div[id*=\"direct_R-A-\"]", ".top-banner-container",
            "div[class*=\"listSuperBanner\"]"
        ])
    ]

    private static let googleCosmeticRules: [CosmeticRule] = [
        // Google AdSense / Ad Manager на любых сайтах.
        CosmeticRule(domains: nil, path: nil, selectors: [
            "ins.adsbygoogle", ".adsbygoogle", "div[id^=\"google_ads_\"]", "iframe[id^=\"google_ads_\"]",
            "[id^=\"div-gpt-ad\"]", "div[data-google-query-id]", "iframe[src*=\"googleads.g.doubleclick.net\"]",
            "iframe[src*=\"tpc.googlesyndication.com\"]", "iframe[src*=\"doubleclick.net\"]"
        ]),

        // Поиск Google: текстовая реклама сверху/снизу и товарные блоки.
        CosmeticRule(domains: googleDomains, path: "/search", selectors: [
            "#tads", "#tadsb", "#bottomads", "#atvcap", "div[data-text-ad]", ".commercial-unit-desktop-top",
            ".commercial-unit-desktop-rhs", ".cu-container", "div[aria-label=\"Ads\"]",
            "div[aria-label=\"Реклама\"]", ".pla-unit-container", "#rhs .cu-container"
        ]),

        // YouTube: реклама в ленте, над плеером, в поиске, Shorts и баннеры.
        CosmeticRule(domains: youTubeDomains, path: nil, selectors: [
            "#masthead-ad", "#player-ads", "ytd-ad-slot-renderer", "ytd-in-feed-ad-layout-renderer",
            "ytd-banner-promo-renderer", "ytd-statement-banner-renderer", "ytd-promoted-sparkles-web-renderer",
            "ytd-promoted-video-renderer", "ytd-compact-promoted-video-renderer", "ytd-display-ad-renderer",
            "ytd-search-pyv-renderer", "ytd-player-legacy-desktop-watch-ads-renderer", "ytd-merch-shelf-renderer",
            "ytd-engagement-panel-section-list-renderer[target-id=\"engagement-panel-ads\"]",
            ".ytp-ad-overlay-container", ".ytp-ad-overlay-slot", ".ytp-ad-image-overlay",
            ".ytp-suggested-action-badge", "ytd-action-companion-ad-renderer", "ytd-companion-slot-renderer",
            "ad-slot-renderer", "ytm-promoted-sparkles-web-renderer", "ytm-companion-ad-renderer",
            "ytm-promoted-video-renderer", "ytd-enforcement-message-view-model"
        ]),
        CosmeticRule(domains: youTubeDomains, path: nil, selectors: [
            "ytd-rich-item-renderer:has(ytd-ad-slot-renderer)",
            "ytd-rich-section-renderer:has(ytd-statement-banner-renderer)",
            "ytd-reel-video-renderer:has(.ytd-ad-slot-renderer)",
            "ytm-rich-item-renderer:has(ad-slot-renderer)",
            "tp-yt-paper-dialog:has(ytd-enforcement-message-view-model)"
        ])
    ]

    // MARK: - Сборка

    /// Правила в формате WKContentRuleList (без исключений — их добавляет AdBlocker).
    static func rules(yandex: Bool, google: Bool) -> [[String: Any]] {
        var rules: [[String: Any]] = []
        let network = (yandex ? yandexNetworkRules : []) + (google ? googleNetworkRules : [])
        let cosmetic = (yandex ? yandexCosmeticRules : []) + (google ? googleCosmeticRules : [])
        for rule in network {
            var trigger: [String: Any] = ["url-filter": rule.filter]
            if rule.thirdPartyOnly { trigger["load-type"] = ["third-party"] }
            if let domains = rule.ifDomain { trigger["if-domain"] = domains }
            if let types = rule.resourceTypes { trigger["resource-type"] = types }
            rules.append(["trigger": trigger, "action": ["type": "block"]])
        }
        for rule in cosmetic {
            var trigger: [String: Any] = [
                "url-filter": rule.path.map { "^https?://[^/]+" + NSRegularExpression.escapedPattern(for: $0) } ?? ".*"
            ]
            if let domains = rule.domains { trigger["if-domain"] = domains }
            // Каждый селектор — отдельное правило: неподдерживаемый селектор не утянет за собой соседей.
            for selector in rule.selectors {
                rules.append(["trigger": trigger, "action": ["type": "css-display-none", "selector": selector]])
            }
        }
        return rules
    }

    // MARK: - Скрипт страницы

    static let scriptMarker = "/* aircraft-adblock-page-script */"

    /// Заменяет скриптлеты uBlock/AdGuard: чистит ответы плеера YouTube от рекламы и
    /// пропускает ролики, которые всё же начались; на Яндексе отключает анти-адблок и
    /// прячет результаты поиска с пометкой «Реклама».
    static func pageScript(yandex: Bool, google: Bool, allowlist: [String]) -> String {
        let allowJSON = (try? JSONSerialization.data(withJSONObject: allowlist))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return scriptMarker + "\n" + pageScriptBody
            .replacingOccurrences(of: "__ALLOWLIST__", with: allowJSON)
            .replacingOccurrences(of: "__YANDEX__", with: yandex ? "true" : "false")
            .replacingOccurrences(of: "__GOOGLE__", with: google ? "true" : "false")
    }

    private static let pageScriptBody = #"""
    (function () {
      'use strict';
      if (window.__aircraftAdShield) return;
      Object.defineProperty(window, '__aircraftAdShield', { value: true });
      var host = location.hostname.toLowerCase().replace(/^www\./, '');
      var allow = __ALLOWLIST__;
      if (allow.some(function (d) { return host === d || host.endsWith('.' + d); })) return;

      var isYouTube = __GOOGLE__ && /(^|\.)(youtube\.com|youtube-nocookie\.com)$/.test(host);
      var isYandex = __YANDEX__ && /(^|\.)(ya\.ru|yandex\.(ru|by|kz|uz|com|com\.tr|com\.am|com\.ge|az|fr))$/.test(host);

      function hide(el) { if (el && el.style) el.style.setProperty('display', 'none', 'important'); }

      // ---------- YouTube ----------
      function youtube() {
        var AD_KEYS = ['adPlacements', 'adSlots', 'playerAds', 'adBreakHeartbeatParams'];
        function strip(r) {
          if (!r || typeof r !== 'object') return;
          for (var i = 0; i < AD_KEYS.length; i++) if (AD_KEYS[i] in r) delete r[AD_KEYS[i]];
          var mr = r.auxiliaryUi && r.auxiliaryUi.messageRenderers;
          if (mr && mr.enforcementMessageViewModel) delete mr.enforcementMessageViewModel;
        }
        function prune(o) {
          try {
            if (o && typeof o === 'object') {
              strip(o);
              if (o.playerResponse) strip(o.playerResponse);
              if (Array.isArray(o)) o.forEach(function (x) { if (x && x.playerResponse) strip(x.playerResponse); });
            }
          } catch (e) {}
          return o;
        }
        // Proxy сохраняет «нативный» вид функций, чтобы не выдавать себя проверкам.
        JSON.parse = new Proxy(JSON.parse, {
          apply: function (t, self, args) { return prune(Reflect.apply(t, self, args)); }
        });
        if (window.Response && Response.prototype.json) {
          Response.prototype.json = new Proxy(Response.prototype.json, {
            apply: function (t, self, args) { return Reflect.apply(t, self, args).then(prune); }
          });
        }
        // Первый ответ плеера встроен в HTML как `var ytInitialPlayerResponse = {…}`.
        var initial;
        try {
          Object.defineProperty(window, 'ytInitialPlayerResponse', {
            configurable: true,
            get: function () { return initial; },
            set: function (v) { initial = prune(v); }
          });
        } catch (e) {}

        // Запасной путь: если реклама всё-таки пошла — без звука проматываем и жмём «Пропустить».
        var mutedByUs = false;
        function tick() {
          var skip = document.querySelector('.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern, .videoAdUiSkipButton');
          if (skip) skip.click();
          var player = document.querySelector('#movie_player, .html5-video-player');
          var video = player && player.querySelector('video');
          if (player && video) {
            var ad = player.classList.contains('ad-showing') || player.classList.contains('ad-interrupting');
            if (ad) {
              if (!video.muted) { video.muted = true; mutedByUs = true; }
              if (isFinite(video.duration) && video.duration > 0 && video.currentTime < video.duration - 0.1) {
                video.currentTime = video.duration;
              }
            } else if (mutedByUs) {
              video.muted = false;
              mutedByUs = false;
            }
          }
          // Окно «Блокировщики рекламы запрещены»: убираем и продолжаем воспроизведение.
          var enforcement = document.querySelector('ytd-enforcement-message-view-model');
          if (enforcement) {
            var dialog = enforcement.closest('tp-yt-paper-dialog') || enforcement;
            dialog.remove();
            document.querySelectorAll('tp-yt-iron-overlay-backdrop').forEach(function (b) { b.remove(); });
            if (video && video.paused) video.play().catch(function () {});
          }
        }
        setInterval(tick, 300);
      }

      // ---------- Яндекс ----------
      function yandex() {
        // abort-on-property-write Object.prototype.adSystem (анти-адблок Яндекса).
        try {
          Object.defineProperty(Object.prototype, 'adSystem', {
            configurable: true,
            get: function () { return undefined; },
            set: function () { throw new ReferenceError('adSystem'); }
          });
        } catch (e) {}

        // Куки-метки, по которым Яндекс включает «обфусцированную» рекламу для блокировщиков.
        var BAD_COOKIE = /blcrm|bltsr|zmFQeXtI|JPIqApiY|computer/;
        var EXPIRED = '=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/';
        function cleanCookies() {
          document.cookie.split(';').forEach(function (c) {
            var name = c.split('=')[0].trim();
            if (!name || !BAD_COOKIE.test(name)) return;
            document.cookie = name + EXPIRED;
            var parts = location.hostname.split('.');
            for (var i = 0; i < parts.length - 1; i++) document.cookie = name + EXPIRED + '; domain=.' + parts.slice(i).join('.');
          });
        }
        cleanCookies();
        window.addEventListener('beforeunload', cleanCookies);
        document.addEventListener('visibilitychange', cleanCookies);

        // Классы на выдаче Яндекс случайные, а вот пометку «Реклама» он обязан показывать.
        // Прячем результаты поиска, у которых есть такая пометка.
        if (!/^\/(search|yandsearch)/.test(location.pathname)) return;
        var LABELS = ['реклама', 'промо', 'ad', 'ads', 'advertisement', 'sponsored', 'reklam'];
        function norm(s) { return (s || '').replace(/[\s ​-‍﻿]+/g, ' ').trim().toLowerCase(); }
        function isLabel(el) {
          var t = el.textContent;
          if (!t || t.length > 20 || LABELS.indexOf(norm(t)) < 0) return false;
          var link = el.closest('a[href]');
          return !link || /yabs\.|\/count\/|\/an\/count/.test(link.getAttribute('href'));
        }
        function isAd(item) {
          if (item.querySelector('[aria-label="Реклама"], [aria-label="Ad"], [title="Реклама"], .AdvLabel, .label_theme_direct')) return true;
          var els = item.querySelectorAll('span, div, b, i, small, label, abbr');
          for (var i = 0; i < els.length; i++) if (isLabel(els[i])) return true;
          return false;
        }
        function scan() {
          var items = document.querySelectorAll('#search-result > *, #search-result-aside > * > *, .content__left .serp-list > *');
          for (var i = 0; i < items.length; i++) if (items[i].style.display !== 'none' && isAd(items[i])) hide(items[i]);
        }
        var pending = false;
        function schedule() {
          if (pending) return;
          pending = true;
          setTimeout(function () { pending = false; scan(); }, 50);
        }
        new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true });
        document.addEventListener('DOMContentLoaded', scan);
      }

      if (isYouTube) youtube();
      if (isYandex) yandex();
    })();
    """#
}
