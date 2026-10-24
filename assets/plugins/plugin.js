(function() {
    /**
     * @typedef {Object} Response
     * @property {boolean} success
     * @property {any} [data]
     * @property {string} [errorCode]
     * @property {string} [message]
     */

    /**
     * @type {import('@skystream/sdk').Manifest}
     */
    // var manifest is injected at runtime

    // ============================================
    // CINEPRO DIRECT HLS PROVIDERS
    // ============================================
    const CINEPRO_DIRECT_PROVIDERS = {
        
        // ==================== VIDSRC ====================
        vidsrc: {
            name: "VidSrc",
            BASE_URL: "https://vsembed.ru/",
            HEADERS: {
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150 Safari/537.36",
                "Referer": "https://vsembed.ru/"
            },
            buildUrl: (media) => media.type === "movie" 
                ? `https://vsembed.ru/embed/movie?tmdb=${media.tmdbId}` 
                : `https://vsembed.ru/embed/tv?tmdb=${media.tmdbId}&season=${media.season}&episode=${media.episode}`,
            parse: async function(html, baseUrl) {
                try {
                    // Step 1: Extract first iframe src
                    const iframe1 = html.match(/<iframe[^>]*src=["']([^"']+)["']/i)?.[1];
                    if (!iframe1) return [];
                    
                    // Step 2: Fetch iframe1, extract second iframe
                    const iframe1Url = iframe1.startsWith("//") ? "https:" + iframe1 : iframe1;
                    const iframe1Html = await fetch(iframe1Url, { headers: this.HEADERS }).then(r => r.text());
                    const iframe2 = iframe1Html.match(/src:\s*['"]([^'"]+)['"]/i)?.[1];
                    if (!iframe2) return [];
                    
                    // Step 3: Fetch iframe2, extract m3u8
                    const iframe2Url = new URL(iframe2, iframe1Url).href;
                    const iframe2Html = await fetch(iframe2Url, { headers: this.HEADERS }).then(r => r.text());
                    
                    // Extract m3u8 from file: "..." pattern
                    const fileField = iframe2Html.match(/file\s*:\s*["']([^"']+)["']/i)?.[1];
                    if (!fileField) return [];
                    
                    // Replace domain placeholders
                    const domains = {
                        '{v1}': 'neonhorizonworkshops.com',
                        '{v2}': 'wanderlynest.com', 
                        '{v3}': 'orchidpixelgardens.com',
                        '{v4}': 'cloudnestra.com'
                    };
                    
                    const urls = fileField.split(/\s+or\s+/i).map(u => {
                        let url = u;
                        for (const [ph, domain] of Object.entries(domains)) {
                            url = url.replace(ph, domain);
                        }
                        return url.includes('{') ? null : url;
                    }).filter(Boolean);
                    
                    return urls.map(url => ({
                        url: url,
                        type: "hls",
                        quality: "Auto",
                        headers: { ...this.HEADERS, Referer: "https://cloudnestra.com/", Origin: "https://cloudnestra.com" }
                    }));
                } catch (e) {
                    return [];
                }
            }
        },

        // ==================== VIXSRC ====================
        vixsrc: {
            name: "VixSrc",
            BASE_URL: "https://vixsrc.to",
            HEADERS: {
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150 Safari/537.36",
                "Accept": "application/json, text/javascript, */*; q=0.01",
                "Accept-Language": "en-US,en;q=0.9",
                "Referer": "https://vixsrc.to",
                "Origin": "https://vixsrc.to"
            },
            buildUrl: (media) => media.type === "movie" 
                ? `https://vixsrc.to/api/movie/${media.tmdbId}` 
                : `https://vixsrc.to/api/tv/${media.tmdbId}/${media.season}/${media.episode}`,
            parse: async function(html, baseUrl) {
                try {
                    // VixSrc: API -> embed -> token -> master playlist
                    const apiData = JSON.parse(html);
                    if (!apiData?.src) return [];
                    
                    // Fetch embed page
                    const embedHtml = await fetch(this.BASE_URL + apiData.src, { headers: this.HEADERS }).then(r => r.text());
                    
                    // Extract token data
                    const token = embedHtml.match(/token["']\s*:\s*["']([^"']+)/)?.[1];
                    const expires = embedHtml.match(/expires["']\s*:\s*["']([^"']+)/)?.[1];
                    const playlist = embedHtml.match(/url\s*:\s*["']([^"']+)/)?.[1];
                    if (!token || !expires || !playlist) return [];
                    
                    // Check token expiry
                    if (parseInt(expires) * 1000 - 60000 < Date.now()) return [];
                    
                    // Build master playlist URL
                    const separator = playlist.includes("?") ? "&" : "?";
                    const masterUrl = `${playlist}${separator}token=${token}&expires=${expires}&h=1`;
                    
                    // Fetch master playlist and parse variants
                    const playlistContent = await fetch(masterUrl, { headers: { ...this.HEADERS, Referer: baseUrl } }).then(r => r.text());
                    
                    // Parse HLS variants for quality
                    const variants = [];
                    const regex = /#EXT-X-STREAM-INF:[^\n]*RESOLUTION=\d+x(\d+)[^\n]*\n([^\n]+)/g;
                    let match;
                    while ((match = regex.exec(playlistContent)) !== null) {
                        variants.push({ resolution: parseInt(match[1]), url: match[2] });
                    }
                    
                    if (variants.length === 0) return [];
                    
                    return variants.map(v => ({
                        url: new URL(v.url, masterUrl).href,
                        type: "hls",
                        quality: v.resolution + "p",
                        headers: { ...this.HEADERS, Referer: baseUrl }
                    }));
                } catch (e) {
                    return [];
                }
            }
        },

        // ==================== VIDAPI ====================
        vidapi: {
            name: "VidApi",
            BASE_URL: "https://vaplayer.ru",
            IFRAME_URL: "https://brightpathsignals.com",
            API_URL: "https://streamdata.vaplayer.ru/api.php",
            HEADERS: {
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                "Referer": "https://brightpathsignals.com/",
                "Origin": "https://brightpathsignals.com",
                "Accept": "*/*"
            },
            buildUrl: (media) => {
                const url = new URL("https://streamdata.vaplayer.ru/api.php");
                url.searchParams.set("tmdb", media.tmdbId);
                url.searchParams.set("type", media.type === "movie" ? "movie" : "tv");
                if (media.type === "tv" && media.season != null && media.episode != null) {
                    url.searchParams.set("season", String(media.season));
                    url.searchParams.set("episode", String(media.episode));
                }
                return url.toString();
            },
            parse: async function(html, baseUrl) {
                try {
                    const data = JSON.parse(html);
                    if (data?.status_code !== "200" || !data.data) return [];
                    
                    const sources = [];
                    for (const streamUrl of data.data.stream_urls || []) {
                        const isHLS = !streamUrl.includes(".mp4") && !streamUrl.includes(".mkv");
                        sources.push({
                            url: streamUrl,
                            type: isHLS ? "hls" : "mp4",
                            quality: "Auto",
                            headers: this.HEADERS
                        });
                    }
                    return sources;
                } catch (e) {
                    return [];
                }
            }
        },

        // ==================== 2EMBED ====================
        twoembed: {
            name: "2Embed",
            BASE_URL: "https://www.2embed.cc",
            HEADERS: {
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150 Safari/537.36",
                "Referer": "https://www.2embed.cc/"
            },
            buildUrl: (media) => media.type === "movie" 
                ? `https://www.2embed.cc/embed/${media.imdbId}` 
                : `https://www.2embed.cc/embed/${media.imdbId}/${media.season}/${media.episode}`,
            parse: async function(html, baseUrl) {
                try {
                    // 2Embed typically has direct m3u8 in page
                    const m3u8 = html.match(/["'](https?:\/\/[^"']+\.m3u8[^"']*)["']/i)?.[1];
                    return m3u8 ? [{ url: m3u8, type: "hls", quality: "Auto", headers: this.HEADERS }] : [];
                } catch (e) {
                    return [];
                }
            }
        }
    };

    /**
     * Loads the home screen categories.
     * @param {(res: Response) => void} cb 
     */
    async function getHome(cb) {
        try {
            cb({ 
                success: true, 
                data: { 
                    "Trending": [
                        new MultimediaItem({ 
                            title: "Example Movie (Carousel)", 
                            url: `${manifest.baseUrl}/movie`, 
                            posterUrl: `https://placehold.co/400x600.png?text=Trending+Movie`, 
                            type: "movie",
                            bannerUrl: `https://placehold.co/1280x720.png?text=Trending+Banner`,
                            description: "Plot summary here...",
                            headers: { "Referer": `${manifest.baseUrl}` }
                        })
                    ],
                    "Latest Series": [
                        new MultimediaItem({ 
                            title: "Example Series (Thumb)", 
                            url: `${manifest.baseUrl}/series`, 
                            posterUrl: `https://placehold.co/400x600.png?text=Series+Poster`, 
                            type: "series",
                            description: "This category appears as a thumbnail row."
                        })
                    ]
                } 
            });
        } catch (e) {
            cb({ success: false, errorCode: "PARSE_ERROR", message: e.stack });
        }
    }

    /**
     * Searches for media items.
     * @param {string} query
     * @param {number} page
     * @param {(res: Response) => void} cb 
     */
    async function search(query, page, cb) {
        try {
            cb({ 
                success: true, 
                data: [
                        new MultimediaItem({ 
                            title: "Example Movie (Search Result)", 
                            url: `${manifest.baseUrl}/movie`, 
                            posterUrl: `https://placehold.co/400x600.png?text=Search+Movie`, 
                            type: "movie", 
                            bannerUrl: `https://placehold.co/1280x720.png?text=Search+Banner`,
                            description: "Plot summary here...", 
                            headers: { "Referer": `${manifest.baseUrl}` } 
                        }),
                        new MultimediaItem({ 
                            title: "Example Series (Search Result)", 
                            url: `${manifest.baseUrl}/series`, 
                            posterUrl: `https://placehold.co/400x600.png?text=Search+Series`, 
                            type: "series", 
                            description: "A series found in search.", 
                            headers: { "Referer": `${manifest.baseUrl}` } 
                        })
                ] 
            });
        } catch (e) {
            cb({ success: false, errorCode: "SEARCH_ERROR", message: e.stack });
        }
    }

    /**
     * Loads details for a specific media item.
     * @param {string} url
     * @param {(res: Response) => void} cb 
     */
    async function load(url, cb) {
        try {
            cb({ 
                success: true, 
                data: new MultimediaItem({
                    title: "Example Series Full Details",
                    url: url,
                    posterUrl: `https://placehold.co/400x600.png?text=Series+Details`,
                    type: "series", 
                    bannerUrl: `https://placehold.co/1280x720.png?text=Series+Banner`,
                    description: "This is a detailed description of the media.", 
                    year: 2024,
                    score: 8.5,
                    duration: 120,
                    status: "ongoing",
                    contentRating: "PG-13",
                    logoUrl: `https://placehold.co/200x100.png?text=Logo`,
                    isAdult: false,
                    tags: ["Action", "Adventure"],
                    cast: [
                        new Actor({ name: "John Doe", role: "Protagonist", image: "https://placehold.co/200x300.png" })
                    ],
                    trailers: [
                        new Trailer({ name: "Official Trailer", url: "https://www.youtube.com/watch?v=..." })
                    ],
                    nextAiring: new NextAiring({ episode: 5, season: 1, airDate: "2024-04-01" }),
                    recommendations: [
                        new MultimediaItem({ title: "Similar Show", url: `${manifest.baseUrl}/similar`, posterUrl: "https://placehold.co/400x600", type: "series" })
                    ],
                    playbackPolicy: "none",
                    syncData: { "my_service_id": "12345" },
                    streams: [
                        new StreamResult({ url: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8", source: "Instant High" })
                    ],
                    headers: { "Referer": `${manifest.baseUrl}` }, 
                    episodes: [
                        new Episode({ 
                            name: "Episode 1", 
                            url: `${manifest.baseUrl}/watch/1`, 
                            season: 1, 
                            episode: 1, 
                            description: "Episode summary...", 
                            posterUrl: `https://placehold.co/400x600.png?text=Episode+Poster`,
                            headers: { "Referer": `${manifest.baseUrl}` },
                            streams: []
                        }),
                        new Episode({ 
                            name: "Episode 2", 
                            url: `${manifest.baseUrl}/watch/2`, 
                            season: 1, 
                            episode: 2, 
                            description: "Next episode summary...", 
                            posterUrl: `https://placehold.co/400x600.png?text=Episode+Poster`,
                            headers: { "Referer": `${manifest.baseUrl}` } 
                        })
                    ]
                }) 
            });
        } catch (e) {
            cb({ success: false, errorCode: "LOAD_ERROR", message: e.stack });
        }
    }

    /**
     * Resolves streams for a specific media item or episode.
     * @param {string} url
     * @param {(res: Response) => void} cb 
     */
    async function loadStreams(url, cb) {
        try {
            // Parse the URL to extract media info (tmdbId, imdbId, season, episode, type)
            const media = parseMediaUrl(url);
            if (!media || !media.tmdbId) {
                return cb({ success: false, errorCode: "INVALID_URL", message: "Could not parse media info from URL" });
            }

            const allStreams = [];

            // Try each direct provider in priority order
            for (const [key, provider] of Object.entries(CINEPRO_DIRECT_PROVIDERS)) {
                try {
                    const providerUrl = provider.buildUrl(media);
                    const response = await fetch(providerUrl, { headers: provider.HEADERS });
                    
                    let html;
                    if (providerUrl.includes("/api/") || providerUrl.includes(".php")) {
                        // API endpoint - might return JSON
                        const text = await response.text();
                        html = text;
                    } else {
                        html = await response.text();
                    }

                    const sources = await provider.parse(html, providerUrl);
                    
                    for (const src of sources) {
                        allStreams.push(
                            new StreamResult({
                                url: src.url,
                                source: `${provider.name} ${src.quality || ""}`.trim(),
                                type: src.type,
                                headers: src.headers,
                                behaviorHints: {
                                    proxyHeaders: { request: src.headers }
                                }
                            })
                        );
                    }

                    // If we got streams from this provider, we can stop (priority order)
                    if (allStreams.length > 0) {
                        console.log(`[CinePro] Got ${allStreams.length} streams from ${provider.name}`);
                        break;
                    }
                } catch (e) {
                    console.log(`[CinePro] ${provider.name} failed:`, e.message);
                    // Continue to next provider
                }
            }

            // Fallback: if no direct streams found, return empty (let app fall back to torrents)
            if (allStreams.length === 0) {
                return cb({ success: true, data: [] });
            }

            cb({ success: true, data: allStreams });
        } catch (e) {
            cb({ success: false, errorCode: "STREAM_ERROR", message: String(e) });
        }
    }

    /**
     * Parse media URL to extract tmdbId, imdbId, season, episode, type
     * @param {string} url 
     * @returns {Object|null}
     */
    function parseMediaUrl(url) {
        try {
            // Expected format: {manifest.baseUrl}/movie/{tmdbId} or /series/{tmdbId}/{season}/{episode}
            // Or episode URL: {manifest.baseUrl}/watch/{episodeId}
            const baseUrl = manifest.baseUrl;
            if (!url.startsWith(baseUrl)) return null;

            const path = url.substring(baseUrl.length).replace(/^\/+/, "");
            const parts = path.split("/");
            
            if (parts[0] === "movie" && parts[1]) {
                return { type: "movie", tmdbId: parts[1] };
            } else if (parts[0] === "series" && parts[1]) {
                if (parts[2] && parts[3]) {
                    return { 
                        type: "tv", 
                        tmdbId: parts[1], 
                        season: parseInt(parts[2]), 
                        episode: parseInt(parts[3]) 
                    };
                }
                return { type: "tv", tmdbId: parts[1] };
            } else if (parts[0] === "watch" && parts[1]) {
                // Episode watch URL - would need to resolve episode info
                // For now return minimal info
                return { type: "tv", tmdbId: parts[1] };
            }
        } catch (e) {
            console.log("[CinePro] Failed to parse media URL:", e);
        }
        return null;
    }

    // Export to global scope for namespaced IIFE capture
    globalThis.getHome = getHome;
    globalThis.search = search;
    globalThis.load = load;
    globalThis.loadStreams = loadStreams;
})();