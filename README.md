# nfqws2 for Android

[![KernelSU](https://img.shields.io/badge/KernelSU-Supported-brightgreen.svg)](https://github.com/tiann/KernelSU)
[![Magisk](https://img.shields.io/badge/Magisk-Supported-blue.svg)](https://github.com/topjohnwu/Magisk)
[![APatch](https://img.shields.io/badge/APatch-Supported-orange.svg)](https://github.com/bmax121/APatch)
[![License](https://img.shields.io/badge/License-MIT-lightgrey.svg)](LICENSE)

Полнофункциональный порт **nfqws2** ([zapret2](https://github.com/bol-van/zapret) от bol-van) с поддержкой синтаксиса стратегий Keenetic для Android.

Модуль предназначен для обхода ТСПУ/DPI **нативно на уровне ядра** через подсистему `netfilter` (NFQUEUE). В отличие от VPN-приложений (V2Ray, ByeDPI и др.), этот метод **не создает виртуального сетевого интерфейса (tun)**, не расходует дополнительный заряд батареи и не режет скорость соединения.

---

## ⚡ Особенности

* **Нативная работа через NFQUEUE**: Модификация пакетов «на лету» без поднятия локального VPN-сервиса.
* **Поддержка LuaJIT и Blobs**: Полная совместимость со сложными стратегиями (fake, multisplit, multidisorder, circular, payload modifications).
* **Сменные пресеты (стратегии)**: Готовые конфиги из коробки с возможностью добавлять свои.
* **Фильтрация приложений**: Возможность пускать в обход трафик только выбранных приложений (или исключать ненужные).
* **Полноценный WebUI**: Управление через WebUI прямо из менеджера (KernelSU / APatch) или через приложение MMRL/ KsuWebUI.

📋 Требования к системе

1. Установленный **KernelSU**, **APatch** или **Magisk** (v24+).
2. Архитектура процессора: **ARM64** (`arm64-v8a`), **ARM** (`armeabi-v7a`), **x86**, **x86_64**.

📥 Установка

1. Скачайте последний `.zip` архив из раздела [Releases](../../releases).
2. Установите модуль через менеджер (KernelSU Manager, Magisk App или APatch).
3. Перезагрузите устройство.
4. Служба запустится автоматически при загрузке системы.


🤝 Благодарности

bol-van — за оригинальный и непревзойденный проект zapret.

nfqws-keenetic — за идеи адаптации конфигов и логику авто-стратегий.
Разработчикам KernelSU, Magisk и APatch.
