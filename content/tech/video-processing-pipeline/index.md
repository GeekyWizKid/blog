---
title: 视频处理服务实践：音频抽取、字幕生成与内嵌
date: 2025-09-07
tags: [FFmpeg, Whisper, Pipeline]
categories: [技术]
draft: false
---

项目地址：[video_processing_service](https://github.com/GeekyWizKid/video_processing_service)。

目标很简单：上传视频——自动抽音频——生成字幕——压回视频，尽量“稳”。

<!--more-->

## 一、整体流程

```mermaid
flowchart LR
  U[用户上传] --> Q[队列]
  Q --> A[音频抽取]
  A --> VAD[静音/语音切分]
  VAD --> ASR[ASR 识别]
  ASR --> ALIGN[对齐/纠错]
  ALIGN --> SRT[SRT/ASS]
  SRT --> BURN[FFmpeg 内嵌]
  BURN --> OUT[回传/存储]
```

关键点是“可恢复”和“幂等”。每一步都能落盘中间结果；重复执行不会破坏已有产物。

## 二、FFmpeg 片段

1) 抽取音频：

```bash
ffmpeg -i input.mp4 -vn -ac 1 -ar 16000 -acodec pcm_s16le audio.wav
```

2) 内嵌字幕（烧录）：

```bash
ffmpeg -i input.mp4 -vf subtitles=subtitle.srt:force_style='FontName=Arial,FontSize=20,PrimaryColour=&HFFFFFF&' -c:a copy out.mp4
```

注意 Windows 路径与转义；ASS 比 SRT 可控性更好（阴影/边距）。

## 三、ASR 策略

- 轻量：`faster-whisper` GPU/CPU 自动选择；
- 长音频：VAD 切分 + 重叠拼接，解决漏字；
- 纠错：语言模型做“标点/大小写/专名”纠错；
- 多语言：先语言识别，再选模型；

伪代码：

```python
segments = vad_split('audio.wav')
for seg in segments:
    text = asr(seg.audio)
    text = lm_postprocess(text)
    write_srt(seg.time_range, text)
```

## 四、任务编排与容错

使用队列（Redis/Rabbit）+ Worker：

- “查看/声明/确认” 三段式消费，失败回退；
- 超时与最大重试次数；
- 并发控制与限速（GPU 资源）；

```ts
// pseudo
queue.process('asr', { concurrency: 2 }, async (job) => { /* ... */ })
```

## 五、性能与成本

- 把“昂贵步骤”（ASR）做缓存；相同音频秒回；
- 码率、分辨率自适应；移动端默认硬字幕；
- 批量场景：优先 WAV PCM，减少解码开销。

## 六、上线注意

- 字体版权：ASS 内嵌字体需确认授权；
- 审核与敏感词：字幕可走审核管线；
- 断点续传 + 多分片校验。

结论：把流程拆成“可恢复”的小步骤，就是稳定的秘诀。
