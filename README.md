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


---

## 🛠 Сборка

```bash
python tools/build.py            # -> nfqws2-android-<version>.zip
python tools/build.py out.zip    # явный путь
```

Сборщик пакует **по allow-list**: в архив попадает только перечисленное в
`tools/build.py` (`MODULE_FILES` / `MODULE_DIRS`), и после сборки результат
проверяется — любой путь вне списка считается ошибкой, а не предупреждением.
Поэтому `tests/`, `tools/`, `.workbuddy-ai/`, `.git/` и прошлые релизные архивы
не могут оказаться внутри модуля: чтобы что-то добавить, это нужно осознанно
дописать в список, а не «случайно затянуть» через `zip -r` из корня.

Если архив всё же собран вручную, `customize.sh` при установке удаляет
разработческие каталоги сам. Именно удаляет, а не фильтрует через `unzip -x`:
в unzip `*` не пересекает `/`, поэтому шаблон вида `tests/*` отсекает только
файлы верхнего уровня, а `tests/module/*` распаковывается как обычно.

## 🧪 Тесты

```bash
sh tests/run.sh          # весь регрессионный сьют
sh tests/run.sh --fast   # без медленных проверок службы и геометрии
```

Подробности — [tests/README.md](tests/README.md).

---

🤝 Благодарности

* [bol-van](https://github.com/bol-van) — за оригинальный и непревзойденный проект zapret.
* [nfqws-keenetic](https://github.com/nfqws/nfqws-keenetic) — за идеи адаптации конфигов и логику авто-стратегий.
* Разработчикам [KernelSU](https://github.com/tiann/kernelSU), [Magisk](https://github.com/topjohnwu/magisk) и [APatch](https://github.com/bmax121/APatch).
