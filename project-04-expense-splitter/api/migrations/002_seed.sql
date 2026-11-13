-- Demo data, inserted only once (guarded by the group name).
DO $$
DECLARE
    g BIGINT; a BIGINT; b BIGINT; c BIGINT; e BIGINT;
BEGIN
    IF EXISTS (SELECT 1 FROM groups WHERE name = 'Goa Trip (demo)') THEN
        RETURN;
    END IF;
    INSERT INTO groups(name, currency) VALUES ('Goa Trip (demo)', 'INR') RETURNING id INTO g;
    INSERT INTO members(group_id, name) VALUES (g, 'Asha')  RETURNING id INTO a;
    INSERT INTO members(group_id, name) VALUES (g, 'Ravi')  RETURNING id INTO b;
    INSERT INTO members(group_id, name) VALUES (g, 'Meera') RETURNING id INTO c;

    INSERT INTO expenses(group_id, paid_by, description, amount_cents) VALUES (g, a, 'Hotel', 900000) RETURNING id INTO e;
    INSERT INTO expense_shares VALUES (e, a, 300000), (e, b, 300000), (e, c, 300000);

    INSERT INTO expenses(group_id, paid_by, description, amount_cents) VALUES (g, b, 'Dinner', 240000) RETURNING id INTO e;
    INSERT INTO expense_shares VALUES (e, a, 80000), (e, b, 80000), (e, c, 80000);
END $$;
