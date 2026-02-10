import from uuid { uuid4 }

node payment_details {
    has amount: float,
        payment_id: str = "",
        currency: str = 'USD';
}

walker PaymentReceived {
    has amount: float,
        currency: str = 'USD';

    can process with Root entry {
        payment_node = here ++> payment_details(
            amount=self.amount,
            payment_id=uuid4().hex,
            currency=self.currency
        );
        visit payment_node;
    }

    can report_data with payment_details entry {
        report {
            "status": "Payment Processed",
            "payment_id": here.payment_id,
            "amount": here.amount,
            "currency": here.currency
        };
    }
}

walker get_all_payments {
    can list_payments with Root entry {
        payments = [-->(?:payment_details)];
        report payments;
    }
}

walker set_payment {
    has amount: float,
        currency: str = 'USD';

    can process with Root entry {
        payment_node = here ++> payment_details(
            amount=self.amount,
            payment_id=uuid4().hex,
            currency=self.currency
        );
        visit payment_node;
    }

    can report_data with payment_details entry {
        report {
            "status": "Payment Processed",
            "payment_id": here.payment_id,
            "amount": here.amount,
            "currency": here.currency
        };
    }
}
