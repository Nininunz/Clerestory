# Third-Party Notices & Clean-Implementation Record

Clerestory is based on Open-Yoink, which is a **clean-room implementation**. We referred to the **publicly observable behavior and architectural ideas** of several open-source projects, but did not copy their source code, UI assets, or proprietary implementations. This file records the third-party code that is included and its licenses (Sparkle, mediaremote-adapter, liquid-glass-react), as well as the sources of behavioral reference; if more third-party code or resources are introduced, they will be added here.

> Original statement from OpenYoink (Chinese):
>
> Open-Yoink 是一个**清洁实现（clean-room implementation）**。我们参考了若干开源项目的**公开可观察行为与架构思路**，但没有复制其源代码、UI 素材或专有实现。

## Third-Party Code

The application includes the following third-party code:

1. **Sparkle** (automatic update framework, added via Swift Package Manager, `upToNextMajorVersion: 2.6.0`, actually resolved to 2.10.1). Sparkle is linked into the app as a binary framework and is used to check for updates (an appcast feed on GitHub Pages) and to install update packages (DMGs on GitHub Releases, with EdDSA signature verification).
2. **mediaremote-adapter** (used by the optional Now Playing module, which is off by default and runs entirely locally). Clerestory pins mediaremote-adapter to upstream commit `e3ff5021eb0875858bd05f48d2e9ba2e962d1cf6` and bundles its Perl adapter script, a universal binary `MediaRemoteAdapter.framework` built from that commit's source, and the capability probe client. `--allow-missing-title` is enabled, so a valid playback session with no title shows the player's name. The app does not link private MediaRemote symbols directly; the helper is not launched when the user has not enabled the media module.

### mediaremote-adapter

- Project name: mediaremote-adapter
- Repository: https://github.com/ungive/mediaremote-adapter
- License: BSD 3-Clause
- Copyright: Copyright (c) 2025, Jonas van den Berg and contributors

```
BSD 3-Clause License

Copyright (c) 2025, Jonas van den Berg and contributors

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors
   may be used to endorse or promote products derived from this software without
   specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### Sparkle

- Project name: Sparkle
- Repository: https://github.com/sparkle-project/Sparkle
- License: MIT (full text below, copied verbatim from the `LICENSE` file in the package)

```
Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesiński.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

=================
EXTERNAL LICENSES
=================

bspatch.c and bsdiff.c, from bsdiff 4.3 <http://www.daemonology.net/bsdiff/>:

Copyright 2003-2005 Colin Percival
All rights reserved

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions 
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

--

sais.c and sais.h, from sais-lite (2010/08/07) <https://sites.google.com/site/yuta256/sais>:

The sais-lite copyright is as follows:

Copyright (c) 2008-2010 Yuta Mori All Rights Reserved.

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

--

Portable C implementation of Ed25519, from https://github.com/orlp/ed25519

Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>

This software is provided 'as-is', without any express or implied warranty. In no event will the
authors be held liable for any damages arising from the use of this software.

Permission is granted to anyone to use this software for any purpose, including commercial
applications, and to alter it and redistribute it freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim that you wrote the
   original software. If you use this software in a product, an acknowledgment in the product
   documentation would be appreciated but is not required.

2. Altered source versions must be plainly marked as such, and must not be misrepresented as
   being the original software.

3. This notice may not be removed or altered from any source distribution.

--

SUSignatureVerifier.m:

Copyright (c) 2011 Mark Hamlin.

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```

## Behavioral References (behavior-level research; no code copied)

| Project | Repository | License | What was referenced |
|---|---|---|---|
| HoldMac | https://github.com/Funnyrz/HoldMac | MIT | File-reference-style staging; the idea of heuristic triggering from Finder drags |
| DropKit | https://github.com/chenyuxiaojin/DropKit | MIT | Shelf + menu bar product structure; the idea of a shake-to-summon interaction |
| ShelfMate | https://github.com/stoimeniliev/shelfmate | MIT | NSPanel window behavior; the idea of shake detection |
| NotchPocket | https://github.com/ijashuzain/NotchPocket | MIT | NSPanel + NSItemProvider drag-and-drop structure |
| nab | https://github.com/jameshiew/nab | MIT-0 | Minimal shelf lifecycle and window behavior |
| Dropshit | https://github.com/iamsumanp/Dropshit | MIT | The idea of multi-representation drag-out using fileURL + NSFilePromiseProvider |

> ClipKit (GPL-3.0) was used only as a behavioral reference for the clipboard feature; none of its code was copied.

## Project-Owned Resources

- **App icon**: `Scripts/AppIcon-master.png` was created by the project author using ChatGPT (AI image generation) and selected by hand. Its copyright belongs to the project author personally, and it is released with the project under the MIT License. `Scripts/generate-icon.swift` is a resampling script written by the project itself; it generates every slot in `Assets.xcassets` from the master image.
- All other code, interface, text, and localized strings are original to the project.

## Confirmation Statement for the Current Version

**Clerestory includes Sparkle (MIT) and mediaremote-adapter (BSD 3-Clause), and adapts the appearance design of liquid-glass-react (MIT) (see below); apart from these, it contains no other third-party code, libraries, images, or fonts.** The other projects listed in the "Behavioral References" table are behavior-level references only; none of their code or assets has entered this repository. If a future version introduces more third-party code or resources, their license texts and copyright attributions will be appended to this file.

## Trademark Notice

"Yoink" is a product name of Eternal Storms Software. Neither Clerestory nor Open-Yoink, on which it is based, has any affiliation with or authorization from Eternal Storms Software. They draw only on Yoink's publicly described user behavior and do not copy its code, icons, text, or brand assets.

## Apple Platform

This application is developed using Apple public APIs (AppKit, SwiftUI, UniformTypeIdentifiers, Quick Look, and others) and follows the Apple Developer Program License Agreement.


## Local Appearance customization — liquid-glass-react

The local Appearance build adapts the layered edge-highlight design and decorative elastic response from https://github.com/rdev/liquid-glass-react (local reference version 1.1.1). Native macOS glass provides the optical backdrop; React, SVG displacement maps and the shader generator are not bundled. The original MIT notice is included in the application as `LiquidGlassReact-LICENSE.txt`.

```
Copyright 2025 MAX ROVENSKY

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the “Software”), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```
