import from uuid { uuid4 }

node payment_details {
    has amount: float,
        payment_id: str = uuid4().hex,
        currency: str = 'USD';
}


walker PaymentReceived {
    has amount: float,
        currency: str = 'USD';

    can process with Root entry {
        payment_node =  here ++> payment_details(
            amount=self.amount
        );
        visit payment_node;
    }

    can report_data with payment_details entry {
        response = {
            "status": "Payment Processed",
            "payment_id": here.payment_id,
            "amount": self.amount,
            "currency": here.currency
        };
        user_graph = printgraph(root);
        print("##########");
        print(user_graph);
        print("##########");
        report response;
    }
}

walker test_end_point {
    has query: str;

    can print_query with Root entry {
        print(f"Received query: {self.query}");
        report f"HEllo {self.query}";
    }
}

walker:pub get_all_payments {
    can list_payments with Root entry {
        payments = [here-->];
        report payments;
    }
}

walker:pub set_payment {
    has amount: float,
        currency: str = 'USD';

    can process with Root entry {
        payment_node =  here ++> payment_details(
            amount=self.amount
        );
        visit payment_node;
    }

    can report_data with payment_details entry {
        response = {
            "status": "Payment Processed",
            "payment_id": here.payment_id,
            "amount": self.amount,
            "currency": here.currency
        };
        user_graph = printgraph(root);
        print("##########");
        print(user_graph);
        print("##########");
        report response;
    }
}
