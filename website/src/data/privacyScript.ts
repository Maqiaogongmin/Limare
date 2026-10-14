import { PRIVACY_POLICY } from '../content/privacy';
import { toChatScript } from './scriptFromMarkdown';

const overview = `> **Local-first does not mean network-free.** Limare operates no account service, model relay, or conversation-storage backend. Services you choose can receive relevant data.

*Read this policy in three layers: local storage, selected services, and your controls.*

---

`;
let policy = PRIVACY_POLICY.replace('## Local-first, with third-party services you choose', overview + '## Local-first, with third-party services you choose');
policy = policy.replace('Provider retention, training, and cross-border processing are governed by that provider\'s policies and your account settings. Limare cannot delete data already received by a provider.', '> **Third-party retention:** provider retention, training, and cross-border processing follow the provider\'s policies and your account settings. Limare cannot delete data already received by a provider.');
policy = policy.replace('## Tools, Computer Use, browser, and Hooks', `### A model request, illustrated

\`\`\`text
Your conversation + selected context
                  |
                  v
      Your configured model endpoint
                  ^
                  |
   Included tool results or screenshots
\`\`\`

*This diagram describes possible request content; tools and websites can have separate network paths.*

---

## Tools, Computer Use, browser, and Hooks`);
policy = policy.replace('- Review local conversations, memory, logs, and migration backups separately.\n- Use browser data clearing for the browser profile\'s cookies and site storage.\n- Use third-party account controls for remote retention or credential revocation.', `### Review each storage boundary

1. **Local records**
   - Conversations, memory, and logs.
   - Migration backups and files in your chosen workspaces.
2. **Browser profile**
   - Cookies, site storage, and caches, using the browser data-clearing control.
3. **Third-party services**
   - Remote retention and credential revocation, using each service's account controls.

> **Removing the app is not a complete deletion procedure.** Review local files, Keychain items, browser data, and third-party copies separately.`);
export const PRIVACY_SCRIPT = toChatScript(policy);
