// =============================================================================
// paymentservice (Node.js) — Custom Spans & Metrics
//
// Import and use these helpers in the existing payment service handlers
// to satisfy the assessment's custom instrumentation requirements.
// =============================================================================

'use strict';

const { trace, SpanStatusCode, metrics } = require('@opentelemetry/api');

const tracer = trace.getTracer('paymentservice', '1.0.0');
const meter  = metrics.getMeter('paymentservice', '1.0.0');

// ── Custom metric: payment_attempts_total ──
// Counter tracking payment success/failure as required by the assessment.
const paymentAttempts = meter.createCounter('payment_attempts_total', {
  description: 'Total payment attempts by status',
  unit: '{attempt}',
});

/**
 * Custom span 1: validate-payment-card
 * Wraps the card validation logic in a custom span.
 *
 * @param {object} cardInfo - { number, cvv, expMonth, expYear }
 * @param {Function} validationFn - The actual validation logic
 * @returns {*} Result of validationFn
 */
function traceValidatePaymentCard(cardInfo, validationFn) {
  return tracer.startActiveSpan('validate-payment-card', (span) => {
    try {
      span.setAttribute('payment.card_type', detectCardType(cardInfo.number));
      span.setAttribute('payment.exp_year', cardInfo.expYear);
      const result = validationFn();
      span.setStatus({ code: SpanStatusCode.OK });
      return result;
    } catch (err) {
      span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
      span.recordException(err);
      throw err;
    } finally {
      span.end();
    }
  });
}

/**
 * Custom span 2: process-payment-charge
 * Wraps the actual payment charge logic in a custom span.
 *
 * @param {object} chargeInfo - { amount, currency, orderId }
 * @param {Function} chargeFn - The actual charge logic (async)
 * @returns {Promise<*>} Result of chargeFn
 */
async function traceProcessPaymentCharge(chargeInfo, chargeFn) {
  return tracer.startActiveSpan('process-payment-charge', async (span) => {
    span.setAttribute('payment.amount', chargeInfo.amount);
    span.setAttribute('payment.currency', chargeInfo.currency);
    span.setAttribute('order.id', chargeInfo.orderId);

    try {
      const result = await chargeFn();
      span.setStatus({ code: SpanStatusCode.OK });
      paymentAttempts.add(1, { status: 'success', currency: chargeInfo.currency });
      return result;
    } catch (err) {
      span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
      span.recordException(err);
      paymentAttempts.add(1, { status: 'failure', currency: chargeInfo.currency });
      throw err;
    } finally {
      span.end();
    }
  });
}

function detectCardType(number) {
  if (!number) return 'unknown';
  if (number.startsWith('4')) return 'visa';
  if (number.startsWith('5')) return 'mastercard';
  if (number.startsWith('3')) return 'amex';
  return 'other';
}

module.exports = {
  traceValidatePaymentCard,
  traceProcessPaymentCharge,
  paymentAttempts,
};
