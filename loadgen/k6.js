// Load generator for watching request-based autoscaling actually happen.
//
// Ramps concurrency in stages. The goal is not throughput measurement — it is
// to push llm_d_epp_flow_control_queue_size above the KEDA threshold long
// enough for the HPA's stabilization window to elapse, so you can watch a
// replica (and on GKE, a GPU node) get added and then reclaimed.
//
//   BASE_URL  endpoint, default localhost:8080 (the kind NodePort)
//   MODEL     must match the served model name exactly
//   MAX_VUS   peak concurrency; 24 comfortably saturates one small replica
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend } from 'k6/metrics';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
const MODEL = __ENV.MODEL || 'Qwen/Qwen3.5-4B';
const MAX_VUS = parseInt(__ENV.MAX_VUS || '24', 10);

const ttft = new Trend('time_to_first_byte', true);

export const options = {
  // Stages are long because the HPA stabilization window is 30s locally and
  // 300s on GKE. Shorter bursts get damped away and you see nothing happen.
  stages: [
    { duration: '30s', target: 2 },
    { duration: '2m', target: MAX_VUS },
    { duration: '3m', target: MAX_VUS },
    { duration: '1m', target: 2 },
    { duration: '2m', target: 0 },
  ],
  thresholds: {
    // Deliberately loose: saturation is the point, so errors under load are
    // information rather than failure. Only hard failures matter.
    http_req_failed: ['rate<0.25'],
  },
};

// Varied prefixes so the EPP's prefix-cache scorer has something real to do;
// an identical prompt every time would make cache affinity trivially perfect
// and hide the routing behaviour.
const PROMPTS = [
  'Explain Kubernetes autoscaling to a new engineer:',
  'Write a short haiku about spot instances:',
  'What is the difference between an NLB and an ALB?',
  'Summarise why GPU utilisation is a poor autoscaling signal:',
  'List three ways to reduce LLM inference cost:',
];

export default function () {
  const body = JSON.stringify({
    model: MODEL,
    prompt: PROMPTS[Math.floor(Math.random() * PROMPTS.length)],
    max_tokens: 128,
    temperature: 0.7,
  });

  const res = http.post(`${BASE_URL}/v1/completions`, body, {
    headers: { 'Content-Type': 'application/json' },
    timeout: '120s',
  });

  ttft.add(res.timings.waiting);

  check(res, {
    'status 200': (r) => r.status === 200,
    'has completion': (r) => {
      try {
        return (r.json('choices') || []).length > 0;
      } catch (e) {
        return false;
      }
    },
  });

  sleep(0.5);
}
