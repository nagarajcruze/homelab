## Phase 1: Networking & Connectivity
Q: Why is my container internet not working with Tailscale on the host?

* Answer: Tailscale’s "Stateful Filtering" and its management of /etc/resolv.conf often block Docker’s bridge network from reaching the DNS.
* Counter-Doubt: I don't want to set custom DNS for Docker; it works on my other server with the same setup.
* Answer: Your other server likely has systemd-resolved installed. Without it, Tailscale "hijacks" the DNS file. Installing systemd-resolved and linking the stub-resolver fixes this globally for all containers without manual config.

## Phase 2: Jellyfin & Metadata
Q: Does Jellyfin automatically download thumbnails? It's showing random frames.

* Answer: Yes, but it requires a strict folder structure: Movie Name (Year)/Movie Name.mkv. If it can't "Identify" the movie via TMDb, it defaults to a random frame.
* Counter-Doubt: Can Radarr move movies into folders and rename them automatically?
* Answer: Yes. By importing your library into Radarr and using the "Movie Editor" to change the Root Folder, Radarr will physically create the folders and move the files for you.

### Phase 3: Permissions & Docker Ownership
Q: Radarr says the folder is not writable by user 'abc' (uid 911).

* Answer: You have a "Permission Tug-of-War." Root owns some folders, while the user with ID 911 owns others.
* Counter-Doubt: The files are owned by 911 because of Jellyfin, but Radarr still fails.
* Answer: Even if the file is owned by 911, the parent folder was likely created by root. You must run chown -R 911:911 on the host to ensure the container user has permission to "modify" the folder (which is required for renaming).

## Phase 4: Bypassing ISP Blocks (Prowlarr & FlareSolverr)
Q: My ISP blocks YTS/1337x. Can Radarr use a proxy?

* Answer: Yes, but Prowlarr + FlareSolverr is better. FlareSolverr acts as a "browser" to solve Cloudflare challenges that standard proxies can't.
* Counter-Doubt: Prowlarr is timing out at 60 seconds with "Unable to connect to indexer."
* Answer: You missed the Tags. You must add a tag (e.g., flare) to both the FlareSolverr Proxy settings AND the Indexer settings in Prowlarr. This "glues" them together so the request is routed correctly.

## Phase 5: Quality Profiles & Upgrades
Q: Why is my movie "Green" (Downloaded) at 720p when I want 1080p?

* Answer: Your "Cutoff" (Upgrade Until) was set too low. Radarr thought its job was done.
* Counter-Doubt: It says "Meets Cutoff: WORKPRINT" even though it's a WebRip.
* Answer: In your "Any" profile, WORKPRINT was likely ranked at the bottom but set as the target. Since any file is better than a Workprint, Radarr stopped searching. Moving it to an "HD-1080p" profile with a "WebDL-1080p" cutoff fixed this.

## Phase 6: Custom Formats & Efficiency
Q: Should I download Blu-ray and transcode to x265?

* Answer: No. It wastes CPU power. It’s better to use Radarr to find WEB-DL x265 files directly.
* Counter-Doubt: How do I force Radarr to pick x265?
* Answer: Create a Custom Format with the regex /\b(x265|hevc|h265)\b/i and give it a Score of +100. This makes Radarr prioritize smaller, efficient files over large x264 files.

## Phase 7: Manual Interference
Q: A movie like "[A-X-L](https://www.google.com/search?kgmid=/hkb/91038955&q=can+you+write+down+all+the+questions+I+asked+and+the+answer+you+gave+and+the+counter+doubt+questions+I+asked+and+you+answer+in+a+document+so+I+can+document+it+for+myserlf)" returns wrong search results.

* Answer: The dashes in the name confuse the indexer.
* Counter-Doubt: Prowlarr found it manually, how do I give it to Radarr?
* Answer: Click "Download" in Prowlarr and ensure the Category is set to radarr. Radarr will see the download in qBittorrent, recognize it as "A-X-L," and take over the management automatically.

## Phase 8: Understanding Quality & Formats
Q: What is the difference between Blu-ray, WEB-DL, and WEBRip?

* Answer: It’s a hierarchy of the "Source":
* Blu-ray/Remux: The highest quality (and largest size). Direct copy of a physical disc.
   * WEB-DL: A clean digital copy from a streaming service (Netflix/Apple). Best balance of size and quality.
   * WEBRip: A re-encode of a digital copy. Usually smaller but slightly lower quality.
* Counter-Doubt: If I download a Blu-ray and transcode it to x265, is that better than a WEB-DL?
* Answer: Usually no. Professionally encoded WEB-DLs are excellent. Manually transcoding Blu-rays wastes electricity and your CPU’s life. It's better to find a high-quality WEB-DL x265 directly.

## Phase 9: Radarr Quality Logic (Sliders & Scores)
Q: Why does Radarr have HD720p, HD1080p, and HD720/1080?

* Answer:
* HD720p/1080p: Strict limits (only those resolutions).
   * 720/1080: A "Flexible" profile that gets you the 720p version fast, then upgrades to 1080p later when found.
* Counter-Doubt: How does the "Max Quality" slider work? Why do I need a 12GB limit for a 4GB file?
* Answer: The slider is GiB per hour, not total file size. For short movies, a low slider might accidentally block a high-quality (dense) 4GB x265 file. Setting it higher (10-15 GiB/h) creates a "buffer" so your Custom Format scores can decide the winner instead of the size limit.

## Phase 10: Docker & File Containers
Q: Why use MKV instead of MP4?

* Answer: MKV is like a pro cargo crate. It supports multiple subtitle tracks, high-end audio (Atmos/DTS), and is more "crash-resistant." MP4 is a basic suitcase—good for compatibility, but bad for high-end movie features.
* Counter-Doubt: Does downsizing only work for MP4?
* Answer: No. Size depends on the Codec (H.264 vs H.265), not the container (MKV vs MP4). An MKV using H.265 will be much smaller than an MP4 using H.264.

## Phase 11: The "Path Paradox" (Docker Volume Mappings)
Q: qBittorrent finished the download, but Radarr says "No files found to import."

* Answer: Each container sees the world differently. qBit said the file was at /data/downloads, but Radarr didn't have a /data folder.
* The Fix: We used Remote Path Mapping in Radarr to "translate" qBit's path into a path Radarr could understand (/downloads).

## Phase 12: Advanced Docker & Linux Permissions
Q: What does user: 0:0 mean in a Docker Compose file?

* Answer: It forces the container to run as the Root user and Root group.
* The Conflict: While it solves permission issues, any file the container creates will be owned by root, potentially locking out your other containers (like Radarr) that run as user 1000. It is also a security risk.

Q: If a parent folder is owned by root, can user 1000 still access a child folder it owns?

* Answer: Yes, but only if the parent folder has the "Execute" (x) permission bit set (e.g., chmod +x).
* The Logic: In Linux, you need "Execute" permission to "pass through" a folder to reach its subdirectories, even if you don't own the parent.

## Phase 13: Music Management (Navidrome)
Q: What is the suggested way to run Navidrome?

* Answer: Run it as user 1000:1000 to match your stack. Mount your music library as Read-Only (:ro) so the app can play your music but can't accidentally delete or modify your files.

