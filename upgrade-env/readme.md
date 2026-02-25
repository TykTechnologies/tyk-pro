# Upgrade Tests

This folder contains files needed for upgrade tests. In these tests, we use an already created dump of the database containing APIs, keys, policies, etc.
Tests are executed in pipeline [here](https://github.com/TykTechnologies/tyk-analytics/actions/workflows/upgrade-tests.yml).

This version of the database dump was created using version 5.3. Two types of databases are supported: postgres15 and mongo7.

To start the environment, follow all standard steps in the [Main README](../README.md) and execute the command:
```
task local-dump FLAVOUR=pro-ha DB=mongo7
```
or
```
task local-dump FLAVOUR=pro-ha DB=postgres15
```

## Updating the Database
### Important: If you need to add anything to the database, please remember to add it to all supported databases!
To add something to the database:
1. Start the environment with the old version (currently 5.3).
2. Introduce the needed change (using the UI or API).
3. Commit the `data_dump` folder.
4. Commit the `redis_data` folder (if needed).
5. Add new data in the `.env` file (if tests need it).
6. Repeat all steps for the second database type.

Do not change the names of the folders!
