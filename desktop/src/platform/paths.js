'use strict';

// Forwards to the seam for the platform we are on. See which.js.
const { platformDirectory } = require('./which');

// eslint-disable-next-line import/no-dynamic-require, global-require
module.exports = require(`./${platformDirectory()}/paths`);
