import from uuid { uuid4 }

node payment_details {
    has amount: float,
        payment_id: str = uuid4().hex,
        currency: str = 'USD';
}

walker:pub set_payment {
    has amount: float,
        currency: str = 'USD';

    can process with Root entry {
        payment_node = here ++> payment_details(amount=self.amount);
        visit payment_node;
    }

    can report_data with payment_details entry {
        report {
            "status": "Payment Processed",
            "payment_id": here.payment_id,
            "amount": self.amount,
            "currency": here.currency
        };
    }
}

walker:pub get_all_payments {
    can list_payments with Root entry {
        payments = [here-->];
        report payments;
    }
}
