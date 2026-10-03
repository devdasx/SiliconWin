@echo off
rem SiliconWin: Windows Setup runs this as SYSTEM right before the first sign-in.
for %%d in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
    if exist %%d:\SiliconWin\install.cmd (
        call %%d:\SiliconWin\install.cmd > "%WINDIR%\Temp\SiliconWin-install.log" 2>&1
        goto :done
    )
)
:done
exit /b 0
