"""Private address authorization, isolation, ownership and migration regressions."""
import pytest

from services import db, private_locations as places, private_location_api, dashboard
from tests.test_routines import setup, request, form, queue
from tests.test_mobile_auth import state
from services.mobile_accounts import AccountError


def call(setup, method, path, user=1, data=None):
    return request(setup, method, 'data/'+path, user=user, data=data)


def address(**changes):
    return {'name': 'My school', 'latitude': 14.6, 'longitude': 121,
            'timezone': 'Asia/Manila', **changes}


def test_members_can_save_private_addresses_without_administrator(setup, monkeypatch):
    monkeypatch.setattr(private_location_api, 'monitor_location', lambda *_: {'ok': True})
    result = call(setup, 'POST', 'locations', data=address())
    assert result.status_code == 201
    location = result.json['location']
    assert location['name'] == 'My school'
    assert any(row['id'] == location['id'] for row in call(setup, 'GET', 'locations').json['locations'])
    assert all(row['id'] != location['id'] for row in call(setup, 'GET', 'locations', user=2).json['locations'])
    assert db.get_location(location['id']) is None
    assert all(row['id'] != location['id'] for row in db.get_locations())
    assert location['id'] in [row['id'] for row in db.get_locations(include_private=True)]


def test_matching_names_never_overwrite_another_users_coordinates(setup):
    one = places.create(1, **address())
    two = places.create(2, **address(latitude=15.5))
    assert one['id'] != two['id']
    assert places.get_location(1, one['id'])['latitude'] == 14.6
    assert places.get_location(2, two['id'])['latitude'] == 15.5
    assert places.create(1, **address())['id'] == one['id']


@pytest.mark.parametrize('method,path', [('GET','dashboard?location=1'), ('POST','refresh'), ('DELETE','locations/1')])
def test_cannot_read_refresh_or_remove_another_users_address(setup, method, path):
    result = call(setup, method, path, user=2, data={'location_id': 1} if method=='POST' else None)
    assert result.status_code == 404
    assert places.get_location(1, 1)['is_active'] is True


def test_dashboard_only_receives_the_members_location_list(setup, monkeypatch):
    seen=[]
    def build(**kwargs):
        seen.append(kwargs)
        return {'location': {'id':kwargs['location_id']}, 'locations':kwargs['scoped_locations']}
    monkeypatch.setattr(dashboard, 'build_dashboard', build)
    result = call(setup, 'GET', 'dashboard?location=1')
    assert result.status_code == 200
    assert [row['id'] for row in result.json['dashboard']['locations']] == [1]
    assert seen[0]['location_id'] == 1


def test_personal_routes_require_session_and_csrf_and_do_not_unlock_shared_routes(setup):
    client, _, tokens = setup
    assert client.get('/api/mobile/data/locations').status_code == 401
    headers={'Authorization':'Bearer '+tokens[0]}
    assert client.post('/api/mobile/data/locations', headers=headers, json=address()).status_code == 400
    result=client.post('/api/locations', headers=headers, json=address(), environ_base={'REMOTE_ADDR':'192.168.1.25'})
    assert result.status_code == 401
    config=client.get('/api/mobile/config',headers=headers).json
    assert config['can_manage_personal_locations'] is True
    assert config['is_admin'] is False


def test_address_picker_saves_the_resolved_private_address(setup, monkeypatch):
    monkeypatch.setattr(private_location_api.addresses, 'resolve_address', lambda **_: address())
    monkeypatch.setattr(private_location_api, 'monitor_location', lambda *_: {'ok': True})
    result=call(setup,'POST','locations/address',data={'region_code':'test'})
    assert result.status_code == 201
    assert result.json['location']['name'] == 'My school'
    assert result.json['location']['id'] not in [row['id'] for row in places.list_locations(2)]


def test_remove_last_address_pauses_routines_and_preserves_ownership(setup, monkeypatch):
    queue(setup,monkeypatch)
    assert call(setup,'DELETE','locations/1').status_code == 200
    assert places.list_locations(1) == []
    assert len(places.list_locations(2)) == 1
    assert setup[1].execute('SELECT enabled FROM mobile_routines').fetchone()[0] == 0
    assert setup[1].execute('SELECT state FROM mobile_notification_deliveries').fetchone()[0] == 'cancelled'
    assert db.get_location(1) is None
    assert places.create(1, **address(name='Quezon City'))['id'] == 1
    assert setup[1].execute('SELECT enabled FROM mobile_routines').fetchone()[0] == 0


def test_routines_cannot_use_someone_elses_address(setup):
    result=request(setup,'POST','routines',user=2,data=form(location_id=1))
    assert result.status_code == 400


@pytest.mark.parametrize('change',[{'latitude':'nan'},{'longitude':181},{'latitude':True},{'timezone':'Bad/Zone'},{'name':''}])
def test_invalid_addresses_are_not_saved(setup,change):
    with pytest.raises(AccountError):
        places.create(1,**address(**change))


def test_limit_is_per_account_and_does_not_create_orphaned_locations(setup,monkeypatch):
    monkeypatch.setattr(places,'LIMIT',2)
    places.create(1,**address())
    before=setup[1].execute('SELECT COUNT(*) FROM locations').fetchone()[0]
    with pytest.raises(AccountError):
        places.create(1,**address(name='Another place'))
    assert setup[1].execute('SELECT COUNT(*) FROM locations').fetchone()[0] == before
    assert places.create(2,**address())['id']


def test_legacy_routine_address_is_copied_without_changing_public_location(setup):
    database=setup[1]
    database.execute("INSERT INTO locations (id,name,latitude,longitude,timezone,is_active) VALUES (10,'Public area',14.5,121,'Asia/Manila',1)")
    database.execute("INSERT INTO mobile_routines (user_id,title,location_id,routine_time,weekdays,timezone,created_at,updated_at) VALUES (1,'Legacy school',10,'08:00','0,1,2,3,4','Asia/Manila',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)")
    database.commit()
    places.migrate_routine_locations()
    new=database.execute('SELECT location_id FROM mobile_routines').fetchone()[0]
    assert new != 10
    assert places.get_location(1,new)['name'] == 'Public area'
    assert db.get_location(10)['name'] == 'Public area'
    assert [row['id'] for row in db.get_locations()] == [10]
    places.migrate_routine_locations()
    assert database.execute('SELECT location_id FROM mobile_routines').fetchone()[0] == new


def test_deleted_account_does_not_make_its_address_public(setup):
    setup[1].execute('DELETE FROM mobile_users WHERE id=1')
    setup[1].commit()
    assert db.get_location(1) is None
    assert 1 not in [row['id'] for row in db.get_locations(include_private=True)]
