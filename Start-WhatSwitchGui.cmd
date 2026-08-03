@echo off
start "What Switch?" pwsh.exe -NoLogo -NoProfile -STA -WindowStyle Hidden -File "%~dp0Start-WhatSwitchGui.ps1" %*
