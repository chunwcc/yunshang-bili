export interface DashVideoStream {
  id: number;
  baseUrl: string;
  backupUrl: string;
  codecid: number;
  bandwidth: number;
  width: number;
  height: number;
  frameRate: string;
  sar: string;
  startWithSap: number;
  contentLength: number;
}

export interface DashAudioStream {
  id: number;
  baseUrl: string;
  backupUrl: string;
  bandwidth: number;
  contentLength: number;
}

export interface DashMpdParams {
  durationMs: number;
  videoStreams: Array<DashVideoStream>;
  audioStreams: Array<DashAudioStream>;
  videoInitRange: string;
  videoIndexRange: string;
  audioInitRange: string;
  audioIndexRange: string;
  /** ⭐ 媒体时基（从 moov/mdhd 解析）；缺省 1000 */
  videoTimescale?: number;
  audioTimescale?: number;
  /** ⭐ 首个子段时长（SegmentTemplate 用；单位=对应轨 timescale） */
  videoSegmentDuration?: number;
  audioSegmentDuration?: number;
}

function codecIdToString(codecid: number): string {
  if (codecid === 7) {
    return 'avc1.640032';
  }
  if (codecid === 12) {
    return 'hev1.1.6.L120.B0';
  }
  if (codecid === 13) {
    return 'av01.0.08M.08';
  }
  return 'avc1.640032';
}

export function buildSegmentBaseMpd(params: DashMpdParams): string {
  const durationPt = `PT${Math.floor(params.durationMs / 1000)}.${String(params.durationMs % 1000).padStart(3, '0')}S`;
  const videoTs: number = params.videoTimescale || 1000;
  const audioTs: number = params.audioTimescale || 1000;

  let videoReps = '';
  for (let i = 0; i < params.videoStreams.length; i++) {
    const v = params.videoStreams[i];
    const indexAttr = params.videoIndexRange
      ? ` indexRange="${params.videoIndexRange}"`
      : '';
    videoReps +=
      `    <Representation id="${v.id}" bandwidth="${v.bandwidth}" width="${v.width}" height="${v.height}" frameRate="${v.frameRate}" codecs="${codecIdToString(v.codecid)}" sar="${v.sar}">\n` +
      `      <BaseURL>video.m4s</BaseURL>\n` +
      `      <SegmentBase timescale="${videoTs}"${indexAttr}>\n` +
      `        <Initialization range="${params.videoInitRange}"/>\n` +
      `${params.videoIndexRange ? `        <RepresentationIndex range="${params.videoIndexRange}"/>\n` : ''}` +
      `      </SegmentBase>\n` +
      `    </Representation>\n`;
  }

  let audioReps = '';
  for (let i = 0; i < params.audioStreams.length; i++) {
    const a = params.audioStreams[i];
    const indexAttr = params.audioIndexRange
      ? ` indexRange="${params.audioIndexRange}"`
      : '';
    audioReps +=
      `    <Representation id="${a.id}" bandwidth="${a.bandwidth}" codecs="mp4a.40.2" audioSamplingRate="48000">\n` +
      `      <AudioChannelConfiguration schemeIdUri="urn:mpeg:dash:23003:3:audio_channel_configuration:2011" value="2"/>\n` +
      `      <BaseURL>audio.m4s</BaseURL>\n` +
      `      <SegmentBase timescale="${audioTs}"${indexAttr}>\n` +
      `        <Initialization range="${params.audioInitRange}"/>\n` +
      `${params.audioIndexRange ? `        <RepresentationIndex range="${params.audioIndexRange}"/>\n` : ''}` +
      `      </SegmentBase>\n` +
      `    </Representation>\n`;
  }

  const mpd =
    '<?xml version="1.0" encoding="UTF-8"?>\n' +
    '<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" profiles="urn:mpeg:dash:profile:isoff-main:2011" type="static" ' +
    `mediaPresentationDuration="${durationPt}" minBufferTime="PT1.5S">\n` +
    '  <Period id="0" start="PT0S">\n' +
    `    <AdaptationSet id="0" contentType="video" mimeType="video/mp4" segmentAlignment="true" startWithSAP="1" subsegmentAlignment="true" subsegmentStartsWithSAP="1">\n` +
    videoReps +
    '    </AdaptationSet>\n' +
    `    <AdaptationSet id="1" contentType="audio" mimeType="audio/mp4" segmentAlignment="true" startWithSAP="1" lang="und">\n` +
    audioReps +
    '    </AdaptationSet>\n' +
    '  </Period>\n' +
    '</MPD>';

  return mpd;
}

/**
 * ⭐ SegmentTemplate 形态——逐项对齐 akamai bbb_30fps.mpd（真机已验证能播的样本）:
 *   - MPD 根加 <BaseURL>./</BaseURL>
 *   - profiles 含 hbbtv 前缀 + isoff-live
 *   - minBufferTime="PT2.00S"
 *   - SegmentTemplate 放在 AdaptationSet 级（继承给全部 Representation）
 *   - startNumber="1"（media 从 _1 起）
 * AVPlayer 26 实测只认分段式 DASH；B 站单文件 m4s 由 loader 虚拟分段
 * （video_init.m4s / video_seg_$Number$.m4s）。
 */
export function buildSegmentTemplateMpd(params: DashMpdParams): string {
  const durationPt = `PT${Math.floor(params.durationMs / 1000)}.${String(params.durationMs % 1000).padStart(3, '0')}S`;
  const videoTs: number = params.videoTimescale || 1000;
  const audioTs: number = params.audioTimescale || 1000;
  const videoDur: number = params.videoSegmentDuration || 1000;
  const audioDur: number = params.audioSegmentDuration || 1000;

  let videoReps = '';
  // ⭐ 多视频轨（实验）：Representation 各自携带 SegmentTemplate（不同 init/media 路径），
  //    让播放器能按 ABR 在轨间切换 —— 单轨时保持原 video_seg_/video_init.m4s 不变。
  const multiVideo: boolean = params.videoStreams.length > 1;
  for (let i = 0; i < params.videoStreams.length; i++) {
    const v = params.videoStreams[i];
    const mediaName: string = multiVideo ? `v${i}_seg_\$Number\$.m4s` : 'video_seg_\$Number\$.m4s';
    const initName: string = multiVideo ? `v${i}_init.m4s` : 'video_init.m4s';
    videoReps +=
      `    <Representation id="${v.id}" bandwidth="${v.bandwidth}" width="${v.width}" height="${v.height}" frameRate="${v.frameRate}" codecs="${codecIdToString(v.codecid)}" sar="${v.sar}" scanType="progressive">\n` +
      (multiVideo
        ? `      <SegmentTemplate timescale="${videoTs}" duration="${videoDur}" media="${mediaName}" startNumber="1" initialization="${initName}"/>\n`
        : '') +
      `    </Representation>\n`;
  }

  let audioReps = '';
  for (let i = 0; i < params.audioStreams.length; i++) {
    const a = params.audioStreams[i];
    audioReps +=
      `    <Representation id="${a.id}" bandwidth="${a.bandwidth}" codecs="mp4a.40.2" audioSamplingRate="48000">\n` +
      `      <AudioChannelConfiguration schemeIdUri="urn:mpeg:dash:23003:3:audio_channel_configuration:2011" value="2"/>\n` +
      `    </Representation>\n`;
  }

  const mpd =
    '<?xml version="1.0" encoding="UTF-8"?>\n' +
    '<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" profiles="urn:hbbtv:dash:profile:isoff-live:2012,urn:mpeg:dash:profile:isoff-live:2011" type="static" ' +
    `mediaPresentationDuration="${durationPt}" minBufferTime="PT2.00S">\n` +
    ' <BaseURL>./</BaseURL>\n' +
    ' <Period>\n' +
    `  <AdaptationSet mimeType="video/mp4" contentType="video" subsegmentAlignment="true" subsegmentStartsWithSAP="1" par="16:9">\n` +
    (multiVideo
      ? ''
      : `   <SegmentTemplate timescale="${videoTs}" duration="${videoDur}" media="video_seg_\$Number\$.m4s" startNumber="1" initialization="video_init.m4s"/>\n`) +
    videoReps +
    '  </AdaptationSet>\n' +
    `  <AdaptationSet mimeType="audio/mp4" contentType="audio" subsegmentAlignment="true" subsegmentStartsWithSAP="1">\n` +
    `   <SegmentTemplate timescale="${audioTs}" duration="${audioDur}" media="audio_seg_\$Number\$.m4s" startNumber="1" initialization="audio_init.m4s"/>\n` +
    audioReps +
    '  </AdaptationSet>\n' +
    ' </Period>\n' +
    '</MPD>';

  return mpd;
}

/**
 * 播放器会为一段 fixed-duration 的 SegmentTemplate 请求多少段？
 * @param periodMs   清单时长（mediaPresentationDuration，毫秒）
 * @param timescale  该轨 timescale
 * @param segTicks   SegmentTemplate @duration（单位 = timescale）
 */
export function askSegmentCount(periodMs: number, timescale: number, segTicks: number): number {
  if (segTicks <= 0 || timescale <= 0) {
    return 0;
  }
  return Math.ceil(periodMs / 1000 * timescale / segTicks);
}

/**
 * ⭐ 求 SegmentTemplate 的 @duration（单位 = 该轨 timescale）——**保证播放器不会越过真实段数**。
 *
 * 背景（2026-09-19 修）：本工程的 MPD 是 SegmentTemplate + 固定 duration，播放器按
 *     请求段数 = ceil(清单时长 / @duration)
 * 推算要拉几段。而清单时长取的是接口给的 timelength，它**常常比 `段数 × 首段时长` 大一点点**
 * （实测 BV1hb411c7RQ：75007ms vs 15×5000ms = 75000ms）⇒ ceil 多算出一段 ⇒ 结尾去请求
 * 不存在的 video_seg_16.m4s ⇒ 转播站 404 ⇒ 该轨停在最后几帧、AVPlayer 抛
 * 5411007 IO Resource Not Found 直接进入 error 态（后续 seek/播放全废）；
 * 而另一轨与进度条（timeUpdate）继续走 ⇒ 就是「最后几秒画面静止 / 结尾报错」。
 *
 * 做法：@duration = max(首段时长, ceil(清单时长 / 段数))，并留 1ms 冗余
 *  （防播放器用 `floor(T/D)+1` 而不是 `ceil(T/D)` 计段 —— T/D 恰好整除时两者会差一段）。
 * ⇒ 绝不会多请求段；常规视频（段数 × 首段 ≥ 清单时长）算出来就是原值，**行为零变化**。
 */
export function safeSegmentTemplateTicks(
  periodMs: number,
  segCount: number,
  firstSegTicks: number,
  timescale: number
): number {
  const ts: number = timescale > 0 ? timescale : 1000;
  if (segCount <= 0) {
    return ts;   // 兜底 1s
  }
  const firstMs: number = firstSegTicks > 0 ? firstSegTicks / ts * 1000 : 0;
  // 让 ceil(T/D) ≤ segCount 的最小 D
  const needMs: number = Math.ceil(periodMs / segCount);
  let dMs: number = firstMs > needMs ? firstMs : needMs;
  // 冗余 1ms：兼容 floor(T/D)+1 的计段方式
  if (Math.floor(periodMs / dMs) + 1 > segCount) {
    dMs += 1;
  }
  const ticks: number = Math.ceil(dMs / 1000 * ts);
  if (ticks > 0) {
    return ticks;
  }
  return firstSegTicks > 0 ? firstSegTicks : ts;
}

export interface BaseMpdParams {
  durationMs: number;
  videoStreams: Array<DashVideoStream>;
  audioStreams: Array<DashAudioStream>;
}

export function buildBaseMpd(params: BaseMpdParams): string {
  const durationPt = `PT${Math.floor(params.durationMs / 1000)}.${String(params.durationMs % 1000).padStart(3, '0')}S`;

  let videoReps = '';
  for (let i = 0; i < params.videoStreams.length; i++) {
    const v = params.videoStreams[i];
    videoReps +=
      `    <Representation id="${v.id}" bandwidth="${v.bandwidth}" width="${v.width}" height="${v.height}" frameRate="${v.frameRate}" codecs="${codecIdToString(v.codecid)}" sar="${v.sar}">\n` +
      `      <BaseURL>video.m4s</BaseURL>\n` +
      `    </Representation>\n`;
  }

  let audioReps = '';
  for (let i = 0; i < params.audioStreams.length; i++) {
    const a = params.audioStreams[i];
    audioReps +=
      `    <Representation id="${a.id}" bandwidth="${a.bandwidth}" codecs="mp4a.40.2" audioSamplingRate="48000">\n` +
      `      <AudioChannelConfiguration schemeIdUri="urn:mpeg:dash:23003:3:audio_channel_configuration:2011" value="2"/>\n` +
      `      <BaseURL>audio.m4s</BaseURL>\n` +
      `    </Representation>\n`;
  }

  const mpd =
    '<?xml version="1.0" encoding="UTF-8"?>\n' +
    '<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" profiles="urn:mpeg:dash:profile:isoff-main:2011" type="static" ' +
    `mediaPresentationDuration="${durationPt}" minBufferTime="PT1.5S">\n` +
    '  <Period id="0" start="PT0S">\n' +
    `    <AdaptationSet id="0" contentType="video" mimeType="video/mp4" segmentAlignment="true" startWithSAP="1" subsegmentAlignment="true" subsegmentStartsWithSAP="1">\n` +
    videoReps +
    '    </AdaptationSet>\n' +
    `    <AdaptationSet id="1" contentType="audio" mimeType="audio/mp4" segmentAlignment="true" startWithSAP="1" lang="und">\n` +
    audioReps +
    '    </AdaptationSet>\n' +
    '  </Period>\n' +
    '</MPD>';

  return mpd;
}
