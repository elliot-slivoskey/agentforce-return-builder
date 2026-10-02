import { LightningElement, api, track } from 'lwc';
import submitReturnFromForm from '@salesforce/apex/ReturnBuilderService.submitReturnFromForm';
import pollReturnResult from '@salesforce/apex/ReturnBuilderService.pollReturnResult';

const METHOD_RETURN = 'Return';
const METHOD_REPLACE = 'Replacement';

/**
 * Return Builder output CLT.
 *
 * The agent user owns the data: ReturnBuilderAction queries returnable orders,
 * items, images and reason codes SERVER-SIDE and passes them in via `value`
 * (a ReturnBuilderSeed). This component therefore does NO data fetching — it
 * renders `this.value` directly. The only server call it makes is the final
 * submit (submitReturnFromForm), which is bind-free so it survives the ECv2
 * messaging Apex-proxy context.
 */
export default class ReturnBuilder extends LightningElement {
    _value;
    _hydrated = false;

    @track step = 'orders'; // 'orders' | 'items'
    @track loading = true;
    @track errorMessage;
    @track orders = [];
    @track selectedOrder;
    @track items = [];
    @track reasonOptions = [];
    // code -> { allowChoice, defaultMethod }; drives the resolution selector.
    reasonConfig = {};
    @track submitting = false;
    @track submitted = false;
    // Latches true the moment a request event is published. The RMA is then
    // being created asynchronously (possibly still in flight on a timeout), so
    // the submit button stays disabled to prevent a duplicate ReturnOrder.
    @track submitLocked = false;
    @track submitError;
    @track result; // { success, returnOrderNumber, message }

    // ============================================================
    //  Lifecycle — hydrate once from the seed the agent user built
    // ============================================================
    @api
    get value() {
        return this._value;
    }
    set value(v) {
        this._value = this.unwrap(v);
        this.maybeHydrate();
    }

    unwrap(v) {
        if (v == null) return v;
        // Tolerate a { value: {...} } wrapper from the platform envelope.
        if (typeof v === 'object' && !Array.isArray(v) && v.value && typeof v.value === 'object') {
            return v.value;
        }
        return v;
    }

    connectedCallback() {
        this.maybeHydrate();
    }

    // value can arrive via the setter before OR after connectedCallback; hydrate
    // exactly once, as soon as we actually have a seed.
    maybeHydrate() {
        if (this._hydrated || this._value == null) return;
        this._hydrated = true;
        this.hydrate();
    }

    hydrate() {
        this.loading = true;
        this.errorMessage = undefined;
        try {
            const v = this._value || {};
            if (v.errorMessage) {
                this.errorMessage = v.errorMessage;
                return;
            }
            this.buildReasons(v);
            this.orders = (v.orders || []).map((o) => this.decorateOrder(o));

            // If the server resolved the referenced order, open straight to it.
            const resolvedId = v.resolvedOrderSummaryId;
            if (resolvedId) {
                const match = this.orders.find((o) => o.id === resolvedId);
                if (match) {
                    this.openOrder(match);
                    return;
                }
            }
            this.step = 'orders';
        } catch (e) {
            this.errorMessage = this.readError(e);
        } finally {
            this.loading = false;
        }
    }

    // Build the reason dropdown options + the per-reason behaviour map. Prefers
    // the rich `reasons` (derived server-side from the OrderChgReasonCategMap
    // object); falls back to the flat `reasonCodes` (customer may always choose,
    // refund default) for safety.
    buildReasons(v) {
        const rich = Array.isArray(v.reasons) && v.reasons.length ? v.reasons : null;
        const source =
            rich ||
            (v.reasonCodes || []).map((c) => ({
                code: c,
                label: c,
                allowChoice: true,
                defaultMethod: METHOD_RETURN
            }));
        this.reasonOptions = source.map((r) => ({ label: r.label || r.code, value: r.code }));
        this.reasonConfig = {};
        source.forEach((r) => {
            this.reasonConfig[r.code] = {
                allowChoice: r.allowChoice !== false,
                defaultMethod: r.defaultMethod || METHOD_RETURN
            };
        });
    }

    configFor(reasonCode) {
        return (
            (this.reasonConfig && this.reasonConfig[reasonCode]) || {
                allowChoice: true,
                defaultMethod: METHOD_RETURN
            }
        );
    }

    // ============================================================
    //  Decoration (pure — no data calls)
    // ============================================================
    decorateOrder(o) {
        return {
            id: o.id,
            orderNumber: o.orderNumber,
            orderedDate: o.orderedDate,
            status: o.status,
            grandTotal: o.grandTotal,
            currencyCode: o.currencyCode,
            returnableItemCount: o.returnableItemCount,
            rawItems: o.items || [],
            formattedTotal: this.formatCurrency(o.grandTotal, o.currencyCode),
            formattedDate: this.formatDate(o.orderedDate),
            itemCountLabel:
                o.returnableItemCount === 1
                    ? '1 returnable item'
                    : `${o.returnableItemCount} returnable items`
        };
    }

    decorateItem(i) {
        const cap = i.quantityAvailableToReturn || 0;

        // Context pre-fill: the planner may have named this product (preSelected)
        // and/or a reason (presetReasonCode). When a reason is preset, mirror the
        // same config-driven resolution the reason dropdown applies, so a
        // pre-filled item is indistinguishable from one the user set by hand.
        const selected = i.preSelected === true;
        let reasonCode = '';
        let method = '';
        let showMethod = false;
        let quantity = 1;
        if (selected && i.presetReasonCode) {
            const cfg = this.configFor(i.presetReasonCode);
            reasonCode = i.presetReasonCode;
            showMethod = cfg.allowChoice;
            // Honour a stated method only when the reason allows a choice; else
            // the reason's configured default wins.
            method =
                cfg.allowChoice && i.presetMethod ? i.presetMethod : cfg.defaultMethod;
        }
        if (selected && i.presetQuantity) {
            // Apex already clamped this to [1, cap]; clamp again defensively
            // against a stale cap mismatch.
            quantity = Math.max(1, Math.min(i.presetQuantity, cap || i.presetQuantity));
        }

        return {
            id: i.id,
            productId: i.productId,
            name: i.name,
            productCode: i.productCode,
            unitPrice: i.unitPrice,
            currencyCode: i.currencyCode,
            quantityOrdered: i.quantityOrdered,
            quantityReturned: i.quantityReturned,
            cap,
            imageUrl: i.imageUrl,
            hasImage: !!i.imageUrl,
            initials: this.initialsFor(i.name),
            // per-item form state (seeded from the pre-fill when present)
            selected,
            quantity,
            reasonCode,
            method,
            showMethod,
            formattedUnitPrice: this.formatCurrency(i.unitPrice, i.currencyCode),
            historyLabel: this.historyLabel(i)
        };
    }

    historyLabel(i) {
        const ordered = i.quantityOrdered != null ? i.quantityOrdered : '?';
        const returned = i.quantityReturned || 0;
        return returned > 0
            ? `Ordered ${ordered} · ${returned} already returned`
            : `Ordered ${ordered}`;
    }

    // ============================================================
    //  Order step -> item step (all client-side; items are nested)
    // ============================================================
    handleSelectOrder(event) {
        const orderId = event.currentTarget.dataset.id;
        const picked = this.orders.find((o) => o.id === orderId);
        if (picked) this.openOrder(picked);
    }

    openOrder(order) {
        this.selectedOrder = order;
        this.items = (order.rawItems || []).map((i) => this.decorateItem(i));
        this.step = 'items';
    }

    handleBackToOrders() {
        this.step = 'orders';
    }

    // ============================================================
    //  Item step interactions
    // ============================================================
    handleToggleItem(event) {
        const id = event.currentTarget.dataset.id;
        this.items = this.items.map((it) =>
            it.id === id ? { ...it, selected: !it.selected } : it
        );
    }

    handleQtyDecrement(event) {
        this.adjustQty(event.currentTarget.dataset.id, -1);
    }

    handleQtyIncrement(event) {
        this.adjustQty(event.currentTarget.dataset.id, 1);
    }

    adjustQty(id, delta) {
        this.items = this.items.map((it) => {
            if (it.id !== id) return it;
            let q = (it.quantity || 1) + delta;
            if (q < 1) q = 1;
            if (q > it.cap) q = it.cap;
            return { ...it, quantity: q };
        });
    }

    handleReasonChange(event) {
        const id = event.currentTarget.dataset.id;
        const val = event.detail ? event.detail.value : event.target.value;
        const cfg = this.configFor(val);
        // Selecting a reason reveals the Refund/Replacement selector only when the
        // reason allows a choice; either way the method defaults per its config
        // (applied silently when no selector is shown).
        this.items = this.items.map((it) =>
            it.id === id
                ? { ...it, reasonCode: val, method: cfg.defaultMethod, showMethod: cfg.allowChoice }
                : it
        );
    }

    handleMethodChange(event) {
        const id = event.currentTarget.dataset.id;
        const val = event.detail ? event.detail.value : event.target.value;
        this.items = this.items.map((it) =>
            it.id === id ? { ...it, method: val } : it
        );
    }

    handleImageError(event) {
        const id = event.currentTarget.dataset.id;
        this.items = this.items.map((it) =>
            it.id === id ? { ...it, hasImage: false } : it
        );
    }

    async handleSubmit() {
        if (this.submitDisabled) return;
        this.submitting = true;
        this.submitError = undefined;
        try {
            // The guest can't create the RMA directly (OM PSL wall), so submit
            // publishes a request the Automated Process subscriber fulfils, then
            // we poll for the outcome it writes back (~2-4s).
            const res = await submitReturnFromForm({ dataJson: JSON.stringify(this.buildPayload()) });

            // Synchronous rejection (unparseable/empty payload, or publish
            // failed) — nothing was published, so leave the button re-enabled
            // for a retry.
            if (res && !res.pending && !res.success) {
                this.submitError = res.message || 'The return could not be created.';
                return;
            }

            // A request event was published: the RMA is now being created. Latch
            // the lock so a slow/timed-out submit can't be fired again and create
            // a duplicate ReturnOrder.
            this.submitLocked = true;

            const final = (res && res.pending && res.correlationId)
                ? await this.pollForResult(res.correlationId)
                : res;

            this.result = final;
            if (final && final.success) {
                this.submitted = true;
            } else if (final && final.timedOut) {
                // The RMA may still be completing in the background — keep the
                // button locked and reassure rather than invite a re-submit.
                this.submitError = final.message;
            } else {
                // A definite failure from the subscriber (no RMA created) — allow
                // another attempt.
                this.submitLocked = false;
                this.submitError = (final && final.message) || 'The return could not be created.';
            }
        } catch (e) {
            this.submitError = this.readError(e);
        } finally {
            this.submitting = false;
        }
    }

    // Polls for the subscriber's result row. Publish -> createReturnOrder ->
    // result row + guest share typically settles in ~2-4s, so we start checking
    // quickly and poll on a tight interval to resolve as soon as it lands.
    async pollForResult(correlationId) {
        const INITIAL_DELAY_MS = 400; // brief head start for the subscriber
        const INTERVAL_MS = 500;
        const MAX_ATTEMPTS = 40; // ~20s ceiling before we tell the user to check back
        await this.delay(INITIAL_DELAY_MS);
        for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
            let res;
            try {
                res = await pollReturnResult({ correlationId });
            } catch (e) {
                await this.delay(INTERVAL_MS);
                continue; // transient; keep polling
            }
            if (res && !res.pending) {
                return res;
            }
            await this.delay(INTERVAL_MS);
        }
        return {
            success: false,
            pending: false,
            timedOut: true,
            message: 'Your return is taking a little longer than usual to confirm. It may still complete — please check back shortly before trying again.'
        };
    }

    delay(ms) {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        return new Promise((resolve) => setTimeout(resolve, ms));
    }

    // Shape the collected form into the Apex ReturnRequest param.
    buildPayload() {
        const lines = this.selectedItems.map((it) => ({
            orderItemSummaryId: it.id,
            productName: it.name,
            quantity: it.quantity,
            reasonCode: it.reasonCode,
            method: it.method
        }));
        return {
            orderSummaryId: this.selectedOrder ? this.selectedOrder.id : null,
            orderNumber: this.selectedOrder ? this.selectedOrder.orderNumber : null,
            lines
        };
    }

    // ============================================================
    //  Derived state
    // ============================================================
    get selectedItems() {
        return this.items.filter((it) => it.selected);
    }

    get hasSelection() {
        return this.selectedItems.length > 0;
    }

    get methodOptions() {
        return [
            { label: 'Refund', value: METHOD_RETURN },
            { label: 'Replacement', value: METHOD_REPLACE }
        ];
    }

    get canSubmit() {
        const chosen = this.selectedItems;
        if (chosen.length === 0) return false;
        return chosen.every(
            (it) => it.quantity >= 1 && it.quantity <= it.cap && !!it.reasonCode && !!it.method
        );
    }

    get submitDisabled() {
        return !this.canSubmit || this.submitting || this.submitLocked;
    }

    get submitLabel() {
        return this.submitting ? 'Submitting…' : 'Submit return';
    }

    get returnOrderNumber() {
        return this.result ? this.result.returnOrderNumber : undefined;
    }

    // Present only when one or more items were resolved as Replacement: the $0
    // reship fulfillment order created for them.
    get replacementOrderNumber() {
        return this.result ? this.result.replacementOrderNumber : undefined;
    }

    get showForm() {
        return !this.submitted;
    }

    get refundEstimate() {
        let total = 0;
        let currency = 'USD';
        this.selectedItems.forEach((it) => {
            if (typeof it.unitPrice === 'number') {
                total += it.unitPrice * (it.quantity || 0);
            }
            if (it.currencyCode) currency = it.currencyCode;
        });
        return this.formatCurrency(total, currency);
    }

    get summaryLabel() {
        const n = this.selectedItems.length;
        if (n === 0) return 'Select the items you want to return';
        const noun = n === 1 ? 'item' : 'items';
        return `Returning ${n} ${noun} · est. ${this.refundEstimate}`;
    }

    get showOrders() {
        return this.step === 'orders' && !this.loading && !this.submitted;
    }

    get showItems() {
        return this.step === 'items' && !this.loading && !this.submitted;
    }

    get noOrders() {
        return this.showOrders && this.orders.length === 0;
    }

    get noItems() {
        return this.showItems && this.items.length === 0;
    }

    // ============================================================
    //  Formatting helpers
    // ============================================================
    formatCurrency(amount, currencyCode) {
        if (typeof amount !== 'number') return '';
        try {
            return new Intl.NumberFormat('en-US', {
                style: 'currency',
                currency: currencyCode || 'USD'
            }).format(amount);
        } catch (e) {
            return `${currencyCode || ''} ${amount}`.trim();
        }
    }

    formatDate(dt) {
        if (!dt) return '';
        try {
            return new Intl.DateTimeFormat('en-US', {
                year: 'numeric',
                month: 'short',
                day: 'numeric'
            }).format(new Date(dt));
        } catch (e) {
            return '';
        }
    }

    initialsFor(name) {
        if (!name) return '?';
        return name
            .split(/\s+/)
            .filter(Boolean)
            .slice(0, 2)
            .map((w) => w.charAt(0).toUpperCase())
            .join('');
    }

    readError(e) {
        if (e && e.body && e.body.message) return e.body.message;
        if (e && e.message) return e.message;
        return 'Something went wrong. Please try again.';
    }
}