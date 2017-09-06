/* 
Script depends on functions defined for general askbot full text search.
to_tsvector(), add_tsvector_column()

calculates text search vector for the user profile
the searched fields are: 
1) user name
2) user profile
3) group names - for groups to which user belongs
*/
CREATE OR REPLACE FUNCTION get_accounts_user_tsv(user_id integer)
RETURNS tsvector AS
$$
DECLARE
    group_query text;
    user_query text;
    onerow record;
    tsv tsvector;
BEGIN
    group_query = 
        'SELECT user_group.name as group_name ' ||
        'FROM auth_group AS user_group ' ||
        'INNER JOIN accounts_user_groups AS gm ' ||
        'ON gm.user_id= ' || user_id || ' AND gm.group_id=user_group.id';

    tsv = to_tsvector('');
    FOR onerow in EXECUTE group_query LOOP
        tsv = tsv || to_tsvector(onerow.group_name);
    END LOOP;

    user_query = 'SELECT about, username, real_name, email FROM accounts_user WHERE id=' || user_id;
    FOR onerow in EXECUTE user_query LOOP
        tsv = tsv || 
            to_tsvector(onerow.username) || 
            to_tsvector(onerow.real_name) ||
            to_tsvector(onerow.email) ||
            to_tsvector(onerow.about);
    END LOOP;
    RETURN tsv;
END;
$$ LANGUAGE plpgsql;

/* create tsvector columns in the content tables */
SELECT add_tsvector_column('text_search_vector', 'accounts_user');

/* populate tsvectors with data */
UPDATE accounts_user SET text_search_vector = get_accounts_user_tsv(id);

/* one trigger per table for tsv updates */

/* set up accounts_user triggers */
CREATE OR REPLACE FUNCTION accounts_user_tsv_update_handler()
RETURNS trigger AS
$$
BEGIN
    new.text_search_vector = get_accounts_user_tsv(new.id);
    RETURN new;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS accounts_user_tsv_update_trigger ON accounts_user;

CREATE TRIGGER accounts_user_tsv_update_trigger
BEFORE INSERT OR UPDATE ON accounts_user 
FOR EACH ROW EXECUTE PROCEDURE accounts_user_tsv_update_handler();

/* group membership trigger - reindex users when group membership
 * changes */
CREATE OR REPLACE FUNCTION group_membership_tsv_update_handler()
RETURNS trigger AS
$$
DECLARE
    tsv tsvector;
    user_query text;
BEGIN
    IF (TG_OP = 'INSERT') THEN
        user_query = 'UPDATE accounts_user SET username=username WHERE ' ||
            'id=' || new.user_id;
    ELSE
        user_query = 'UPDATE accounts_user SET username=username WHERE ' ||
            'id=' || old.user_id;
    END IF;
    /* just trigger the tsv update on user */
    EXECUTE user_query;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS group_membership_tsv_update_trigger
ON accounts_user_groups;

CREATE TRIGGER group_membership_tsv_update_trigger
AFTER INSERT OR DELETE
ON accounts_user_groups
FOR EACH ROW EXECUTE PROCEDURE group_membership_tsv_update_handler();

/* todo: whenever group name changes - also 
 * reindex users belonging to the group */

DROP INDEX IF EXISTS accounts_user_search_idx;

CREATE INDEX accounts_user_search_idx ON accounts_user
USING gin(text_search_vector);
