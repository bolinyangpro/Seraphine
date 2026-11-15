<#
.SYNOPSIS
    在 Windows 上构建 Seraphine 并替换安装目录，由 scripts/deploy_windows.sh 通过 SSH 调用

.DESCRIPTION
    构建目录 (BuildRoot) 结构：
        python38\     Python 3.8.10（NuGet 的 python 包解压而来，不写注册表）
        venv\         基于 python38 的虚拟环境，安装了 requirements.txt 与 PyInstaller
        tools\uv.exe  用于安装依赖
        src.zip       本次要构建的源码（由 deploy_windows.sh 上传，构建后删除）

    首次准备构建环境（在 Windows 上执行）：
        1. 把 https://www.nuget.org/api/v2/package/python/3.8.10 解压，tools 目录重命名为 BuildRoot\python38
        2. 把 uv 0.5.11 (uv-x86_64-pc-windows-msvc.zip) 解压到 BuildRoot\tools
        3. BuildRoot\tools\uv.exe venv -p BuildRoot\python38\python.exe BuildRoot\venv
    依赖会在每次构建时自动同步。
#>

param(
    [Parameter(Mandatory)] [String]$BuildRoot,
    [Parameter(Mandatory)] [String]$InstallDir
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$BuildRoot = $BuildRoot.Replace('/', '\')
$InstallDir = $InstallDir.Replace('/', '\')

$python = Join-Path $BuildRoot 'venv\Scripts\python.exe'
$uv = Join-Path $BuildRoot 'tools\uv.exe'
$srcZip = Join-Path $BuildRoot 'src.zip'
$srcDir = Join-Path $BuildRoot 'build-src'
$pypi = 'https://pypi.tuna.tsinghua.edu.cn/simple'

foreach ($p in $python, $uv, $srcZip) {
    if (-not (Test-Path $p)) { throw "缺少 $p，请先按脚本顶部说明准备构建环境" }
}

Write-Host "==> 解压源码"
if (Test-Path $srcDir) { Remove-Item $srcDir -Recurse -Force }
Expand-Archive $srcZip $srcDir -Force
Remove-Item $srcZip

try {
    Push-Location $srcDir

    Write-Host "==> 同步依赖"
    $env:UV_CACHE_DIR = Join-Path $BuildRoot 'uv-cache'
    # 这些包较新的版本没有 Python 3.8 的预编译 wheel，禁止源码构建，让 uv 选择有 wheel 的旧版本
    $binaryOnly = 'pyzstd', 'pyppmd', 'pybcj', 'inflate64', 'brotli', 'pycryptodomex',
                  'multidict', 'yarl', 'frozenlist', 'propcache', 'psutil'
    $uvArgs = @('pip', 'install', '-q', '-p', $python, '--index-url', $pypi,
                '-r', 'requirements.txt', 'pyinstaller==5.13.2')
    foreach ($b in $binaryOnly) { $uvArgs += @('--only-binary', $b) }
    & $uv @uvArgs
    if ($LASTEXITCODE -ne 0) { throw "依赖安装失败" }

    Write-Host "==> PyInstaller 打包"
    $env:PATH = (Join-Path $BuildRoot 'venv\Scripts') + ';' + $env:PATH
    $ErrorActionPreference = 'Continue'   # PyInstaller 的日志输出在 stderr
    & .\make.ps1 -dbg 2>&1 | Select-String -Pattern 'ERROR|completed successfully' | ForEach-Object { $_.Line }
    $ErrorActionPreference = 'Stop'

    $dist = Join-Path $srcDir 'dist\Seraphine'
    if (-not (Test-Path (Join-Path $dist 'Seraphine.exe'))) { throw "打包失败，未生成 Seraphine.exe" }

    Write-Host "==> 结束正在运行的 Seraphine"
    $running = @(Get-Process Seraphine -ErrorAction SilentlyContinue)
    # 也结束从源码启动的开发版 (python main.py)
    $devProcs = @(Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" |
        Where-Object { $_.CommandLine -like '*main.py*' })
    $wasRunning = ($running.Count + $devProcs.Count) -gt 0
    $running | Stop-Process -Force
    $devProcs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    if ($wasRunning) { Start-Sleep -Seconds 2 }

    Write-Host "==> 替换安装目录 $InstallDir"
    $backup = "$InstallDir.bak"
    if (Test-Path $backup) { Remove-Item $backup -Recurse -Force }
    if (Test-Path $InstallDir) { Rename-Item $InstallDir (Split-Path $backup -Leaf) }
    try {
        Move-Item $dist $InstallDir
    } catch {
        if (Test-Path $backup) { Rename-Item $backup (Split-Path $InstallDir -Leaf) }
        throw
    }
    if (Test-Path $backup) { Remove-Item $backup -Recurse -Force }

    $exe = Join-Path $InstallDir 'Seraphine.exe'

    Write-Host "==> 更新桌面快捷方式"
    $desktop = [Environment]::GetFolderPath('Desktop')
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut((Join-Path $desktop 'Seraphine.lnk'))
    $lnk.TargetPath = $exe
    $lnk.WorkingDirectory = $InstallDir
    $lnk.Save()

    if ($wasRunning) {
        Write-Host "==> 重新启动 Seraphine"
        # SSH 会话无法直接在桌面上显示窗口，借助一次性计划任务在当前登录的桌面会话中启动
        $taskName = 'SeraphineDeployLaunch'
        $action = New-ScheduledTaskAction -Execute $exe -WorkingDirectory $InstallDir
        $principal = New-ScheduledTaskPrincipal -LogonType Interactive `
            -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
        Start-Sleep -Seconds 3
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }

    Write-Host "==> 部署完成：$exe"
}
finally {
    Pop-Location
    if (Test-Path $srcDir) { Remove-Item $srcDir -Recurse -Force }
}
