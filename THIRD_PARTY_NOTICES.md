# Third-party notices

Totype itself is licensed under the Apache License 2.0 (see `LICENSE`).
The components below are downloaded at build time by `scripts/setup_local_sensevoice.sh`
(SHA-256 verified) and, in a build that bundles the local engine, are copied into the
app bundle under `Contents/Resources/SenseVoice/`. They are not part of this
repository's source tree.

The license texts below were copied from the upstream repositories on 2026-10-02.
Re-check upstream before each release.

| Component | File in the app | Origin | License |
|---|---|---|---|
| SenseVoiceSmall (GGUF, Q8) | `sensevoice-small-q8.gguf` | https://huggingface.co/FunAudioLLM/SenseVoiceSmall-GGUF (converted from https://huggingface.co/FunAudioLLM/SenseVoiceSmall) | FunASR Model Open Source License Agreement v1.1 (the GGUF model card additionally states `apache-2.0`) |
| FSMN-VAD (GGUF) | `fsmn-vad.gguf` | https://huggingface.co/FunAudioLLM/fsmn-vad-GGUF (converted from https://huggingface.co/funasr/fsmn-vad) | Apache License 2.0 (per both model cards) |
| FunASR llama.cpp runtime | `llama-funasr-sensevoice` | https://github.com/QwenAudio/SenseVoice release `runtime-llamacpp-v0.1.9` (`funasr-llamacpp-macos-arm64.tar.gz`) | MIT, Copyright (c) 2025 FunASR |
| ggml / llama.cpp (statically linked into the runtime) | (inside the runtime binary) | https://github.com/ggml-org/llama.cpp (commit 8086439a4cea94c71a5dfb8fe4ad1546aebd640f, as pinned by the runtime's CMakeLists.txt) | MIT, Copyright (c) 2023-2026 The ggml authors |
| miniaudio (audio decoder compiled into the runtime) | (inside the runtime binary) | https://github.com/mackron/miniaudio v0.11.25 | Public domain (Unlicense) or MIT No Attribution, at your option |

## Model attribution (FunASR Model License section 2.2)

SenseVoiceSmall and FSMN-VAD are models by FunASR / FunAudioLLM (Alibaba Group).
The local engine uses them unchanged apart from GGUF conversion and quantization
(`sensevoice-small-q8.gguf` is the Q8 file published by FunAudioLLM). Model names are
kept as published: "SenseVoiceSmall", "FSMN-VAD".

Sources: https://github.com/FunAudioLLM/SenseVoice and https://github.com/modelscope/FunASR

### FunASR Model Open Source License Agreement, Version 1.1 (English text)

FunASR Model Open Source License Agreement

Version: 1.1

Copyright (C) [2023-2028] [Alibaba Group]. All rights reserved.

Thank you for choosing the FunASR open-source model. The FunASR open-source model includes a range of free and open industrial models for you to use, modify, share, and learn from.

To ensure better community collaboration, we have established the following agreement, and we hope you will read and comply with its terms.
Definitions

In this agreement, [FunASR Software] refers to FunASR open-source model weights and their derivatives, including finetuned models; [You] refers to individuals or organizations using, modifying, sharing, and learning from [FunASR Software].

2 License and Restrictions

2.1 License

You are free to use, copy, modify, and share [FunASR Software] under the terms of this agreement.

2.2 Restrictions

When using, copying, modifying, and sharing [FunASR Software], you must attribute the source and author information and retain relevant model names in [FunASR Software].

3 Responsibility and Risk

[FunASR Software] is provided for reference and learning purposes only, and Alibaba Group assumes no responsibility for any direct or indirect losses resulting from your use or modification of [FunASR Software]. You should assume all risks associated with using and modifying [FunASR Software].

4 Community Conduct Guidelines

4.1 Encouraged Behavior

The community welcomes developers and users to engage in discussions about [FunASR Software]. Participants are encouraged to interact in a friendly, polite, and respectful manner to foster constructive discussion and collaboration.

4.2 Prohibited Behavior

Individual or organizational users shall not engage in unjustified denigration, malicious smearing, or baseless insults against [FunASR Software]. Such behavior is considered a violation of the spirit of community cooperation. If a user is found to be engaging in the prohibited behavior mentioned above, it will be considered an automatic forfeiture of all licenses under this agreement.

5 Termination

If you violate any terms of this agreement, your license will automatically terminate, and you must cease using, copying, modifying, and sharing [FunASR Software].

6 Revisions

This agreement may be updated and revised occasionally. The revised agreement will be published in the official repository of [FunASR Software] and will take effect automatically. Continuing to use, copy, modify, and share [FunASR Software] indicates your acceptance of the revised agreement.

7 Miscellaneous

This agreement is governed by the laws of [Country/Region]. If any provision is deemed illegal, invalid, or unenforceable, that provision shall be considered severed from this agreement, and the remaining provisions shall continue to be valid and binding.

If you have any questions or comments regarding this agreement, please contact us.

Copyright © [2023-2028] [Alibaba Group]. All rights reserved.

The agreement is also published in Chinese at the same URL; the Chinese text is the
second half of that file.

### FSMN-VAD

Apache License 2.0, https://www.apache.org/licenses/LICENSE-2.0 (full text in `LICENSE`).

## MIT License: FunASR llama.cpp runtime (SenseVoice)

MIT License
Copyright (c) 2025 FunASR

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

## MIT License: ggml / llama.cpp

MIT License

Copyright (c) 2023-2026 The ggml authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

The runtime binary also contains code marked "MIT licensed. Copyright (c) 2023
Jeffrey Quesnelle and Bowen Peng." (YaRN RoPE scaling, part of ggml's Metal kernels).

## miniaudio

Dual-licensed under the Unlicense (public domain) and MIT No Attribution
(Copyright 2026 David Reid). No attribution is required; listed for completeness.

## Cloud services

Soniox and Alibaba Cloud Model Studio (Bailian) are optional cloud engines used with
your own API key and account. They are governed by those providers' terms; no code or
model from them is distributed with this project.
