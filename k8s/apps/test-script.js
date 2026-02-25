import http from 'k6/http';
import { sleep, check } from 'k6';

// Get environment variables with defaults
const API_NAME = __ENV.API_NAME || 'test';
const TEST_DURATION = __ENV.TEST_DURATION || '30s';
const TARGET_NAMESPACE = __ENV.TARGET_NAMESPACE || 'tyk-dp-1';

export const options = {
  vus: 10,
  duration: TEST_DURATION,
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<500']
  },
  // Add summary export for better output
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)']
};

export default function() {
  // Using httpbin's /get endpoint instead of the Flask /upstream endpoint
  const res = http.get(`http://gateway-svc-tyk-data-plane-tyk-gateway.${TARGET_NAMESPACE}.svc.cluster.local:8080/${API_NAME}/get`);
  check(res, {
    'status is 200': (r) => r.status === 200,
    'response has args': (r) => r.json().hasOwnProperty('args'),
    'response has headers': (r) => r.json().hasOwnProperty('headers'),
  });
  sleep(1);
}