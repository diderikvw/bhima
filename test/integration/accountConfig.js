/* global expect, agent */

const helpers = require('./helpers');

/*
 * The /payroll/account_configuration  API endpoint
 *
 * This test suite implements full CRUD on the /payroll/account_configuration  HTTP API endpoint.
 */
describe('(/payroll/account_configuration) The /payroll/account_configuration  API endpoint', function () {
  // Account Payroll Configuration we will add during this test suite.

  const accountConfig = {
    label : 'Account Configuration 2017',
    account_id : 175,
  };

  const accountConfigUpdate = {
    label : 'Account Configuration 2015',
  };

  const NUM_ACCOUNTING = 1;
  
  it('GET /ACCOUNT_CONFIG returns a list of Account Configurations ', function () {
    return agent.get('/account_config')
      .then(function (res) {
        helpers.api.listed(res, NUM_ACCOUNTING);
      })
      .catch(helpers.handler);
  });

  it('POST /ACCOUNT_CONFIG should create a new Account Configuration', function () {
    return agent.post('/account_config')
      .send(accountConfig)
      .then(function (res) {
        accountConfig.id = res.body.id;
        helpers.api.created(res);
      })
      .catch(helpers.handler);
  });

  it('GET /ACCOUNT_CONFIG/:ID should not be found for unknown id', function () {
    return agent.get('/account_config/unknownAccount')
      .then(function (res) {
        helpers.api.errored(res, 404);
      })
      .catch(helpers.handler);
  });

  it('PUT /ACCOUNT_CONFIG  should update an existing Account Configuration', function () {
    return agent.put('/account_config/'.concat(accountConfig.id))
      .send(accountConfigUpdate)
      .then(function (res) {
        expect(res).to.have.status(200);
        expect(res.body.label).to.equal('Account Configuration 2015');
      })
      .catch(helpers.handler);
  });

  it('GET /ACCOUNT_CONFIG/:ID returns a single Account Configuration', function () {
    return agent.get('/account_config/'.concat(accountConfig.id))
      .then(function (res) {
        expect(res).to.have.status(200);
      })
      .catch(helpers.handler);
  });

  it('DELETE /ACCOUNT_CONFIG/:ID will send back a 404 if the Account Configuration does not exist', function () {
    return agent.delete('/account_config/inknowRubric')
      .then(function (res) {
        helpers.api.errored(res, 404);
      })
      .catch(helpers.handler);
  });

  it('DELETE /ACCOUNT_CONFIG/:ID should delete an Account Configuration ', function () {
    return agent.delete('/account_config/'.concat(accountConfig.id))
      .then(function (res) {
        helpers.api.deleted(res);
      })
      .catch(helpers.handler);
  });

});