@echo off
REM Atalho para quem vive no cmd.exe, que e o caso aqui.
REM
REM 23/09/2026: dois tropecos no mesmo minuto, e os dois sao do cmd, nao da
REM pessoa. Primeiro `.\scripts\ambiente.ps1` nao roda em cmd -- e PowerShell.
REM Depois `cd E:\...` a partir do C: nao troca de DISCO; precisa de `cd /d`,
REM que ja tinha mordido uma vez hoje no `git push`.
REM
REM Este arquivo resolve os dois: roda de qualquer lugar, sem cd nenhum.
REM
REM   scripts\ambiente.cmd            onde estou?
REM   scripts\ambiente.cmd dev        aponta pro DEV
REM   scripts\ambiente.cmd producao   aponta pra PRODUCAO
REM
REM O -ExecutionPolicy Bypass e necessario porque o script nao e assinado, e
REM vale so para esta chamada -- nao mexe na politica da maquina.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ambiente.ps1" %*
