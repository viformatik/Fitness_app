# Восстановление кандидата с UI-проверкой checkpoint — НЕ РЕЛИЗ

Контрольный commit `3752bf82513d5eeb00e10e48d2da96d5621db171`, tree `d14edfc73ffa2308968e9e72ce11bb5a274b00f7`. Реального дневника в этом архиве нет; release gate закрыт.

В новый пустой каталог можно восстановить одним из двух проверенных способов:

1. Проверить SHA-256 `/home/user/fitness_smart_local_clear_checkpoint_browser_WIP_NOT_RELEASE.bundle`: `da008ad1f5a71c61fcd5ef3417ccbc253b3b38536af745ae1c917d264ec90a48`; клонировать и проверить tree.
2. Проверить SHA-256 исходной базы `/home/user/fitness_smart_synthetic_preview_restored_candidate.bundle`: `da094330d3cead7c8ebc6559bf56be8a5f2a00d42caf6fa17b47e6039e984e73`, а также patch `/home/user/fitness_smart_local_clear_checkpoint_browser_WIP_NOT_RELEASE.patch.gz`: `d5432d0f4a56ce0e4ed6301f7ee28f732cd6827a92f34fd1ef0102b2b24f45d1`. Клонировать базу, checkout `3098ed03bc4e606f656f26dde31dd4ed66d8999d`; выполнить `gzip -dc PATCH | git apply --index --check -`, затем `gzip -dc PATCH | git apply --index -`; `git write-tree` должен дать tree выше. `--index` сохраняет отслеживаемые диагностические файлы, даже если они совпадают с `.gitignore`.

Оба варианта проверены на изолированных копиях, tree совпал, bundle прошёл `git fsck`. Инструкции и результаты — `LOCAL_CLEAR_BATCH_RECONSTRUCTION_WIP.md`; `.SHA256` не заменяет архив. Ничего из этого нельзя применять к реальной базе или production как готовый релиз.
