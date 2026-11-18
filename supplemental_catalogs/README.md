# Отдельно восстановленные каталоги

Эти файлы не внесены в `early_source_snapshot/` и не считаются интегрированным кандидатом. Источник и генераторы сохранились отдельно; обе пары Dart/JSON восстановлены детерминированной генерацией. Тест `tools/test_catalog_integrity.py` использует только локальные файлы и временный каталог внутри `checks/`.

```sh
cd supplemental_catalogs
PYTHONDONTWRITEBYTECODE=1 python3 tools/test_catalog_integrity.py
```

Последний локальный результат: **5/5 PASS**. Проверка касается соответствия генераторов и данных, но не доказывает актуальности значений на упаковках, законности повторного использования всех источников, безопасности приложения или готовности к выпуску.

Контрольные SHA-256:

- `lib/smart/local_catalog.dart`: `4e17b536b880c4ab3900d5df348431fe4d9c42a67e5a2e3b4482055588902fe2`
- `lib/smart/regional_foods.dart`: `dd6b091a2e07d7476337892012e7cc6586e5ab41dbad2049defba63b51a6a479`
- `tools/data/pmr_catalog.json`: `10d3afcf75e7059805ca5ec31a3268c7d38bcfa5ac4ed8855ce63c27de4f06b7`
- `tools/data/regional_dairy.json`: `539b40bdbf86313e41e89ad18d36f45c174241b3129475b4e7a0330661fc93c0`
- `tools/data/tirhleb_products.json`: `4039ab15eaf7864beee31f211d32a9a35ce056082a769ad665eaa9291146d63f`
