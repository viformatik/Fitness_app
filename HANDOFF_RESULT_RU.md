# Результат продолжения по `HANDOFF_NEXT_AI.md` — НЕ РЕЛИЗ

Локальная работа выполнена поверх `work/github-reconstruction-synthetic` @
`4e21f0c`. Историческая копия `fitness_smart/` не трогалась. Реальный дневник,
Auth, облако, Vercel и Supabase не использовались.

## Что закрыто

| Пункт handoff | Где | Тесты |
|---|---|---|
| §3.1 P2/C2 — предыдущая копия не теряется | `candidate/lib/smart/local_store.dart`, `candidate/lib/legacy.dart` | `rebuilt_import_retention_test.dart` (3) |
| §3.2 строгая проверка облачных строк | `candidate/lib/smart/remote.dart` | `rebuilt_cloud_malformed_test.dart` (4) |
| §3.3 превью, отдельное удаление, stale-guard | `candidate/lib/legacy.dart`, `candidate/lib/smart/ui.dart` | `rebuilt_backup_safety_test.dart` (10) |
| §3.4 share → браузерная загрузка | `candidate/lib/smart/backup_delivery*.dart`, `pubspec.yaml`, `ui.dart`, `startup_recovery.dart` | входит в 10 тестов выше |
| §4.2 зависание `init()` после импорта | не воспроизведено; добавлен ограниченный регресс | `rebuilt_init_after_import_test.dart` (2) |

## Проверки

- `dart analyze` по изменённым файлам и отдельно по web-файлу — чисто.
- 19 новых тестов — зелёные; затронутые старые регрессы — зелёные.
- Полный прогон (без `postgrest_integration_test.dart`): **672 PASS / 2 FAIL**;
  оба провала подтверждены на чистом `4e21f0c` и не являются регрессиями
  (отсутствующий фикстурный JSON и ошибка поиска виджета в тестовом харнесе).
- Web-сборка `-O1` с `--build-name=3.0.1-synthetic` — успешна.
- Доказательства: `candidate/checks/attempts/REBUILT_FIXES_20261124.{log,json}`.

## Что осталось (осознанно не сделано)

1. **Публикация §8 не выполнялась.** В среде нет токена GitHub; push в ветку,
   коммит с `[skip ci]`, артефакты `NOT_RELEASE` с SHA-256-сидкарами —
   требует отдельного указания/доступа. `main` не трогался.
2. **Браузерная проверка §5/шаг 6 не выполнялась.** Нет Playwright, браузеров
   и изолированного harness; настоящая загрузка файла на диск и системный
   Web Share остаются непроверенными (модульные тесты фейковые).
3. `/home/user/FITNESS_STATUS_NOT_RELEASE.md` из handoff в этой среде
   отсутствует; обновлён только статус внутри репозитория
   (`README.md`, `candidate/CANDIDATE_SAFETY.md`).
4. `postgrest_integration_test.dart` не запускался — нужен реальный PostgreSQL.

Известные риски из handoff (+250 мл ×3 → 500 вместо 750, BFCache, квота,
Safari/iOS, Android, реальная синхронизация) остаются открытыми и не выдаются
за решённые.
