// DataLens host API client for HTML pages. Inline this file's contents into the page's <script>;
// the sandbox blocks loading it from anywhere else. See references/host-api.md.
const DataLens = (() => {
  const DEFAULT_TIMEOUT_MS = 60000;

  const fail = (code, message, extra) => Object.assign(new Error(message), { code }, extra);

  function call(method, args, { timeout = DEFAULT_TIMEOUT_MS } = {}) {
    if (window.parent === window) {
      return Promise.reject(fail('NOT_FRAMED', 'The page is not running inside DataLens'));
    }
    return new Promise((resolve, reject) => {
      const { port1, port2 } = new MessageChannel();
      const timer = setTimeout(() => {
        port1.close();
        reject(fail('TIMEOUT', `${method} got no answer from DataLens`));
      }, timeout);
      port1.onmessage = ({ data }) => {
        clearTimeout(timer);
        port1.close();
        if (data && data.error) {
          const { code, message, status } = data.error;
          reject(fail(code, message, { status }));
        } else {
          resolve(data && data.result);
        }
      };
      window.parent.postMessage({ code: 'API_REQUEST', data: { method, args } }, '*', [port2]);
    });
  }

  return {
    call,
    getDatasetData: (args, options) => call('getDatasetData', args, options),
    getChartData: (args, options) => call('getChartData', args, options),
    getState: (options) => call('getState', undefined, options),
    createState: (data, options) => call('createState', { data }, options),
  };
})();
