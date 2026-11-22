/// Display policy for catalog and product search only. Personal history and
/// saved documents are never rewritten: an existing custom product can be
/// renamed by its owner in settings if its name is hidden from a picker.
final RegExp _cyrillic = RegExp(r'[А-Яа-яЁёІіЇїЄєҐґ]');

// Include Latin-1/extended and full-width Latin letters in addition to ASCII.
// Do not include multiplication/division signs from the Latin-1 block.
final RegExp _latin = RegExp(
  r'[A-Za-z\u00C0-\u00D6\u00D8-\u00F6\u00F8-\u02AF\u1E00-\u1EFF\uAB30-\uAB6F\uFF21-\uFF3A\uFF41-\uFF5A]',
);

bool containsCyrillicProductText(String value) => _cyrillic.hasMatch(value);

/// Requires a Cyrillic letter and rejects Latin letters, including mixed names.
/// This deliberately also hides names containing Latin vitamin abbreviations;
/// the original can be edited explicitly, never silently transliterated.
bool isRussianProductName(String value) =>
    containsCyrillicProductText(value) && !_latin.hasMatch(value);
