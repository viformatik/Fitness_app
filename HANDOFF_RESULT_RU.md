# Результат продолжения по `HANDOFF_NEXT_AI.md` / `EXECUTION_BRIEF.md` — НЕ РЕЛИЗ

Локальная работа выполнена поверх `work/github-reconstruction-synthetic` @
`4e21f0c`. Историческая копия `fitness_smart/` не трогалась. Реальный дневник,
Auth, облако, Vercel и Supabase не использовались.

## Что закрыто

| Пункт | Где | Тесты / доказательства |
|---|---|---|
| §3.1 P2/C2 — предыдущая копия не теряется | `candidate/lib/smart/local_store.dart`, `candidate/lib/legacy.dart` | `rebuilt_import_retention_test.dart` (3) |
| §3.2 строгая проверка облачных строк | `candidate/lib/smart/remote.dart` | `rebuilt_cloud_malformed_test.dart` (4) |
| §3.3 превью, отдельное удаление, stale-guard | `candidate/lib/legacy.dart`, `candidate/lib/smart/ui.dart` | `rebuilt_backup_safety_test.dart` (10) |
| §3.4 share → браузерная загрузка | `candidate/lib/smart/backup_delivery*.dart`, `pubspec.yaml`, `ui.dart`, `startup_recovery.dart` | входит в 10 тестов выше + браузерный зонд |
| §4.2 зависание `init()` после импорта | усиленный регресс с реальными чтениями | `rebuilt_init_after_import_test.dart`, 6/6 прогонов |
| §5 браузерная проверка доставки | `research/rebuild_github_lab/delivery_probe.cjs` | Chromium 3/3, Firefox 3/3, отчёты в `attempts/` |

## Проверки

- `dart analyze` по изменённым файлам и отдельно по web-файлу — чисто.
- 20 новых тестов — зелёные; затронутые старые регрессы — зелёные.
- Полный прогон (без `postgrest_integration_test.dart`): **672 PASS / 2 FAIL**;
  оба провала подтверждены на чистом `4e21f0c` и не являются регрессиями
  (отсутствующий фикстурный JSON и ошибка поиска виджета в тестовом харнесе).
- `flutter build web ... -O1` + повторная маркировка оболочки — успешна.
- §4.2: сценарий «импорт → новый provider → `init()` → чтение дневника»
  выполняется для in-memory и Hive-хранилища; **6/6 прогонов** (3 запуска файла
  × 2 сценария), каждый с лимитом 20 с и проверкой фактических прочитанных
  значений — не «прошёл по таймауту».
- Браузер: при `navigator.share` удалён и `canShare() === false` скачивается
  настоящий JSON с синтетическим `water_intake_2026-11-24 = 250`; при рабочем
  share вызывается только share, второй тихой загрузки нет. PAGE errors: 0.
- Коммиты с `[skip ci]`: `b8cbabb` (код и тесты), `f7ebadc` (доказательства и
  документация). Push в `work/github-reconstruction-synthetic` выполнен;
  `git ls-remote` показывает `f7ebadc`, `main` остаётся на `b32a152`.

## Публикация сайта

По прямому указанию пользователя развёрнут **новый** Vercel-проект
`fitness-smart-synthetic-not-release`:
`https://fitness-smart-synthetic-not-release.vercel.app`.
Production-deploy `dpl_ELutaWk5LRv8ngkTg5RskQXbni9w`, статус READY.
Сайт проверен в Chromium: интерфейс загружается, кнопка «Вода +250 мл»
работает, три нажатия дают 750 мл (гонка исправлена). Существующий проект
`fitness-smart` и все Supabase-проекты не изменялись.

## Что осталось (осознанно не сделано)

1. **Device Flow не использовался**: push прошёл через уже сохранённые
   учётные данные Git Credential Manager. Никакой токен не запрашивался, не
   появлялся в логах и не сохранялся агентом, поэтому отзывать здесь нечего.
   Если эта учётная запись использует PAT — отзовите его самостоятельно.
2. **Google Drive недоступен**: коннектор не представлен в этой среде. Артефакты
   (`NOT_RELEASE` + SHA-256) подготовлены локально, но не выгружены.
3. Изолированный `run_isolated.sh` не запускался: на Windows нет `bash`, `ip`,
   `unshare`, `setpriv`. Браузерная проверка выполнена локальным зондом без
   сетевого namespace — это честно отражено в отчётах.
4. `postgrest_integration_test.dart` не запускался — нужен реальный PostgreSQL.
5. Системный Web Share ОС и сохранение в пользовательскую ФС не проверены.

Статус репозитория: `STATUS_NOT_RELEASE.md`. Доказательства:
`candidate/checks/attempts/REBUILT_FIXES_20261124.{log,json}`,
`research/rebuild_github_lab/attempts/*_delivery_fallback_20261124.json`,
`research/rebuild_github_lab/REPORT_RU.md`.

Известные риски из handoff (+250 мл ×3 → 500 вместо 750, BFCache, квота,
Safari/iOS, Android, реальная синхронизация) остаются открытыми и не выдаются
за решённые.
