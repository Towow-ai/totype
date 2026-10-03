# 01 安装

[English](../en/01-install.md)

可以下载预编译的 dmg 安装，也可以从源码构建。dmg 是不含语音模型的精简版（lite），模型在应用里下载；精简版同样能从源码构建，见方式二。因为应用没有经过 Apple 公证，第一次打开需要多一步手动放行。

## 方式一：预编译 dmg

dmg 发布在 GitHub Releases（`https://github.com/Towow-ai/totype/releases`），文件名是 `Totype-<版本>-arm64.dmg`，同页附带 `SHA256SUMS`。它是精简版，不含本地模型：在入门引导，或 设置 → 识别 的“本地模型”一行里下载，约 246 MB，来自 Hugging Face，下载后校验，保存在 `~/Library/Application Support/Totype/models/`。

也可以用 Homebrew 安装：`brew install --cask towow-ai/tap/totype`。它下载的是同一个 dmg，第一次打开时同样要按下文放行。

1. 下载 dmg 和 `SHA256SUMS`，在下载目录运行 `shasum -a 256 -c SHA256SUMS` 核对（提示 `OK` 即可；只下载了 dmg 时，会提示找不到其他文件，可忽略）。
2. 打开 dmg，把 Totype 拖进“应用程序”文件夹。
3. 在“应用程序”里双击 Totype 。系统会弹出“无法打开”或“无法验证开发者”的提示，点“完成”关闭。
4. 打开 系统设置 → 隐私与安全性，滚到底部，找到关于 Totype 的提示，点“仍要打开”，输入登录密码。
5. 再次启动后，按 [02 首次运行与授权](02-first-run.md) 完成授权。

macOS 15 起，右键点“打开”绕过检查的方法已被取消，所以必须走上面第 3、4 步。习惯命令行的话，可以去掉隔离标记，然后直接打开：

```bash
xattr -dr com.apple.quarantine /Applications/Totype.app
```

## 方式二：从源码构建

源码构建会把本地模型一起打包进应用，等同于完整版。只需要 Xcode 命令行工具（Command Line Tools），不要求安装完整的 Xcode；SDK 需要 macOS 15.4 或更高。

1. 安装命令行工具：`xcode-select --install`。
2. 克隆仓库：`git clone https://github.com/Towow-ai/totype.git`，进入目录。
3. 可选：复制 `config/local.env.example` 为 `config/local.env`，按需修改应用名、Bundle ID 和签名身份（见下文“签名与授权稳定性”）。
4. 运行 `scripts/install.sh`。它会构建应用，安装到 `/Applications/Totype.app`，已有版本会先备份，并在安装后启动。
5. 只想构建、不安装时运行 `scripts/build.sh`，结果在 `build/` 目录下。这个产物带 `.disabled` 后缀，不能直接双击运行，需要用 `scripts/install.sh` 安装。

首次构建会下载约 246 MB 的运行程序和模型，并校验固定的 SHA-256，下载缓存在 `.build/downloads/`。网络慢或需要代理时，可以先自行下载到一个目录，再用环境变量 `VERBATIM_SENSEVOICE_DIR` 指向它。该目录需要包含 `llama-funasr-sensevoice`、`sensevoice-small-q8.gguf` 和 `fsmn-vad.gguf` 三个文件。

想构建不含模型的精简版，运行 `VERBATIM_BUNDLE_MODEL=0 scripts/build.sh`（`scripts/install.sh` 加同样的前缀也行）。精简版在首次使用时下载模型：用入门引导，或 设置 → 识别 里的“本地模型”一行。这一行的状态有“已内置”“已下载”“未安装”（带“下载”按钮）“下载中”（显示进度和“取消”）“校验失败”（带“重试”）。只用云端引擎的话，可以不装模型。

### 签名与授权稳定性

macOS 把麦克风、辅助功能和输入监控的授权绑定在应用的代码签名上。如果没有可用的签名身份，构建脚本会退回 ad-hoc 签名并打印警告，此后每次重新构建，签名都会变化，系统可能撤销已有授权。运行 `scripts/install_local_signing_identity.sh` 会在登录钥匙串里创建一个本机自签名身份，名称取自 `VERBATIM_SIGN_IDENTITY`，之后的构建使用同一身份，授权可以跨构建保留。

## 更新

- 源码构建：拉取新代码后再次运行 `scripts/install.sh`。
- dmg：下载新版本，覆盖“应用程序”里的旧版本。

未经公证的构建在更新之后，系统可能让三项授权失效。症状是热键没反应，或菜单面板顶部出现“Esc 取消不可用：需要重新授权输入监控”。处理方法：打开 系统设置 → 隐私与安全性，在“麦克风”“辅助功能”“输入监控”三个列表里删掉 Totype 的旧条目，重新添加或重新授权，再重启应用。

## 卸载

1. 如果开启过“登录后自动启动”，先在历史窗口的“设置”页的“高级与诊断”里关掉它。
2. 退出应用，把 `/Applications/Totype.app` 移到废纸篓。
3. 要清除数据，按 [07 数据与隐私](07-data-and-privacy.md) 的“清除全部数据”一节操作。
4. 在 系统设置 → 隐私与安全性 的三个列表里删掉 Totype，或执行 `tccutil reset All ai.towow.totype`。
