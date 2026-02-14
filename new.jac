import from uuid { UUID, uuid4 }

node payment_details {
    has amount: float,
        payment_id: UUID = :> uuid4,
        currency: str = 'USD';
}

walker PaymentReceived {
    has amount: float,
        currency: str = 'USD';

    can process with Root entry {
        payment_node = here ++> payment_details(
            amount=self.amount,
            currency=self.currency
        );
        visit payment_node;
    }

    can report_data with payment_details entry {
        report {
            "status": "Payment Processed",
            "payment_id": str(here.payment_id),
            "amount": here.amount,
            "currency": here.currency
        };
    }
}

walker test_end_point {
    has query: str;

    can print_query with Root entry {
        print(f"Received query: {self.query}");
        report f"Hello {self.query}";
    }
}

walker get_all_payments {
    can list_payments with Root entry {
        report [here-->];
    }
}

walker set_payment {
    has amount: float,
        currency: str = 'USD';

    can process with Root entry {
        payment_node = here ++> payment_details(
            amount=self.amount,
            currency=self.currency
        );
        visit payment_node;
    }

    can report_data with payment_details entry {
        report {
            "status": "Payment Processed",
            "payment_id": str(here.payment_id),
            "amount": here.amount,
            "currency": here.currency
        };
    }
}
