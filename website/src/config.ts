import facts from '../../release-facts.json';

export const CONFIG = {
  appName: facts.product,
  version: facts.version,
  downloadEnabled: facts.downloadEnabled,
  downloadURL: 'https://github.com/Maqiaogongmin/Limare/releases/latest/download/Limare.dmg',
  githubURL: 'https://github.com/Maqiaogongmin/Limare',
  developerName: facts.developer,
  effectiveDate: '2026-10-14',
  privacyContact: facts.contact,
};
