# Context variables
####################

# Useful to ensure files produced in volumes over docker-compose exec
# commands are not "root privileged" files.
export HOST_UID=$(shell id -u)
export HOST_GID=$(shell id -g)
export HOST_ID=${HOST_UID}:${HOST_GID}

# PROJECT_NAME defaults to name of the current directory.
# should not be changed if you follow GitOps operating procedures.
export PROJECT_NAME = $(notdir $(PWD))

# export CURRENT_DATE = $(shell date +"%Y%m%d")

export INFRA_SCRIPT_PATH = $(shell realpath ./scripts)
export INFRA_CACHE_PATH = $(shell realpath ./infra/cache)
export INFRA_ENV_BASE_PATH = $(shell realpath ./infra/env)
export INFRA_SRC_BASE_PATH = $(shell realpath ./src)


ifneq (,$(wildcard ${INFRA_ENV_BASE_PATH}/deploy.env))
    include ${INFRA_ENV_BASE_PATH}/deploy.env
    export
endif
# export DOCKER_PSH_IMG=${DOCKER_REGISTRY_BASE_PATH}/${DOCKER_PSH_IMG_PATH}/${DOCKER_PSH_IMG_NAME}:${DOCKER_PSH_IMG_TAG}
# export INFRA_DOCKER_PROXY=${DOCKER_REGISTRY_BASE_PATH}/dockerhub
export INFRA_DOCKER_PATH = $(shell realpath ./infra/docker)
export INFRA_ENV_PATH = ${INFRA_ENV_BASE_PATH}/data/${DEPLOY_ENV}
export INFRA_SRC_PSH = ${INFRA_SRC_BASE_PATH}/prestashop

# Include services *.env files

# ifneq (,$(wildcard ${INFRA_ENV_PATH}/networks.env))
#     include ${INFRA_ENV_PATH}/networks.env
#     export
# endif

ifneq (,$(wildcard ${INFRA_ENV_PATH}/proxy.env))
    include ${INFRA_ENV_PATH}/proxy.env
    export
endif

# TODO : use environment variables for Prestashop
# ifneq (,$(wildcard ${INFRA_ENV_PATH}/presta.env))
#     include ${INFRA_ENV_PATH}/presta.env
#     export
# endif

# Docker environment setup
export DOCKER_NETWORK = $(PROJECT_NAME)/network


## Meta commands used for internal purpose
############################################

# This guard meta command allows to check if environment variable is defined 
guard-%:
	@if [ -z '${${*}}' ]; then echo 'ERROR: variable $* not set' && exit 1; fi


## Infra
#########

infra-init: services-config-all infra-run services-init-all
# 	make services-reload-all

infra-run: guard-DOCKER_COMPOSE
	${DOCKER_COMPOSE} up -d --remove-orphans

infra-watch: infra-run logs

# stop containers and processes
infra-stop: guard-DOCKER_COMPOSE 
	${DOCKER_COMPOSE} stop 

infra-restart: infra-stop infra-run

# we dissociate 'env' from 'infra' to avoid deployment "mistakes".
# env is reserved for "risky" operations

# This command :
# 	- prepares "env files" and services configuration structures according template.
#	- download prestashop sources (submodule)
env-init: guard-INFRA_ENV_PATH guard-INFRA_ENV_BASE_PATH guard-INFRA_SRC_PSH
	mkdir -p ${INFRA_ENV_PATH}
	cp -r ${INFRA_ENV_BASE_PATH}/template/* ${INFRA_ENV_PATH}
	git submodule update --init

# Usefull for prestashop-deploy dev purpose : reset environment to fresh configured project 
# WARNING : remove all docker objects (even other projects one)
env-reset: clean-all env-docker-clean config-restore psh-clean-infra-cache
	rm -rf ${INFRA_SRC_PSH}
	git submodule update --init

# Usefull for prestashop-deploy dev purpose : rebuild environment to test docker and environment 
# env-rebuild: psh-clean-artefacts env-docker-clean docker-build-dev infra-init

# Complete docker environment purge
# WARNING : This command will purge all docker environment (all projects)
# TODO : Look for a "softer" reset solution 
# 	https://github.com/docker/compose/issues/6159#issuecomment-862999377
#	https://docs.docker.com/engine/reference/commandline/compose/#use--p-to-specify-a-project-name
env-docker-clean:
	- docker stop $(shell docker ps -a -q)
	- docker rm -v $(shell docker ps -a -q)
	- docker volume rm $(shell docker volume ls -q -f dangling=true)
	- docker network rm $(shell docker network ls -q --filter type=custom)
	- docker rmi $(shell docker images -a -q) -f
	- docker builder prune -f
	- docker system prune -a -f

# WARN this command should be used during dev only cause it prints some credentials
env-log:
	@printf '\n ==== Makefile ENV  ==== \n\n'
	@printenv | sort
	@printf '\n ==== psh.app ENV  ==== \n\n'
	make log-psh.app
	@${EXEC_PSH_APP} 'printenv | sort'
	@printf "\n ==== psh.db ENV  ==== \n\n"
	@${EXEC_PSH_DB} 'printenv | sort'
	@printf '\n ==== psh.cli.npm ENV  ==== \n\n'
	@${EXEC_PSH_CLI_NPM} 'printenv | sort'


## Diagnostic
##############

logs: guard-DOCKER_COMPOSE
	$(DOCKER_COMPOSE) ps
	$(DOCKER_COMPOSE) logs -f --tail=100

# TODO : review npm log commands
log-psh.cli: guard-EXEC_PSH_APP guard-EXEC_PSH_CLI_NPM
	${EXEC_PSH_APP} 'composer show'
	${EXEC_PSH_APP} 'composer status'
	${EXEC_PSH_APP} 'composer diagnose'
	${EXEC_PSH_CLI_NPM} 'npm check'

log-psh.app: guard-EXEC_PSH_APP
	@${EXEC_PSH_APP} 'printenv | sort'
	@${EXEC_PSH_APP} 'php bin/console debug:container --env-vars'
# 	@${EXEC_PSH_APP} 'php bin/console fop:environment:get-parameters'
# 	${DOCKER_COMPOSE} logs -f psh.app

log-proxy-env: guard-DOCKER_COMPOSE
	${DOCKER_COMPOSE} exec proxy.nginx printenv | sort
	${DOCKER_COMPOSE} exec proxy.letsencrypt printenv | sort

log-system:
	printenv
	docker info
	df -h
	docker system df
# 	docker stats

# TODO : add an history graph view
# git log --pretty=format:"%h %s" --graph --since=1.weeks


## Config
##########

# This command moves current environment configuration to a backup directory. 
# TODO : should we allow silent backup remove ?
config-backup: guard-INFRA_ENV_BASE_PATH guard-DEPLOY_ENV
	-[ -d ${INFRA_ENV_PATH} ] && { rm -rf ${INFRA_ENV_BASE_PATH}/backup/${DEPLOY_ENV} && mkdir ${INFRA_ENV_BASE_PATH}/backup/${DEPLOY_ENV}; }
	-mv ${INFRA_ENV_PATH}/* ${INFRA_ENV_BASE_PATH}/backup/${DEPLOY_ENV}
	rm -rf ${INFRA_ENV_PATH}

# This command restores current environment configuration.
config-restore: guard-INFRA_ENV_BASE_PATH guard-DEPLOY_ENV
	rm -rf ${INFRA_ENV_PATH}
	mkdir ${INFRA_ENV_PATH}
	- cp -r ${INFRA_ENV_BASE_PATH}/backup/${DEPLOY_ENV}/* ${INFRA_ENV_PATH}

# Remove environment variable names from services configuration files to apply their values
# TODO : make envsubst quiet/silent
# config-apply-env: guard-INFRA_ENV_PATH
# 	find ${INFRA_ENV_PATH} -type f | xargs -I {} sh -c "envsubst < {} | tee {}"


## Clean
#########

clean-config: config-backup
	rm -rf ${INFRA_ENV_PATH}

# clean-psh-cache:
# 	${DOCKER_COMPOSE} exec -u www-data:www-data -w ${DOCKER_PSH_WORKDIR} psh.app php bin/console ...
# 	cache:clear
# 	cache:pool:clear
# 	cache:pool:prune
# 	cache:warmup
# 	doctrine:cache:clear-*

clean-all: clean-config


## Shell
#########

shell-psh.db: guard-EXEC_PSH_DB
	${EXEC_PSH_DB} '/bin/bash'

shell-psh.mysql: guard-EXEC_PSH_DB
	${EXEC_PSH_DB} 'mysql -u prestashop_admin --password=prestashop_admin prestashop'

shell-psh.app: guard-EXEC_PSH_APP
	${EXEC_PSH_APP} '/bin/bash'
	
shell-psh.cli.npm: guard-EXEC_PSH_CLI_NPM
	${EXEC_PSH_CLI_NPM} '/bin/bash'
	
shell-psh.app-sudo: guard-DOCKER_COMPOSE
	${DOCKER_COMPOSE} exec -u root:root psh.app sh -c '/bin/bash'
# 	${DOCKER_COMPOSE} exec -u ${HOST_ID} psh.app sh -c '/bin/bash'

shell-proxy: guard-DOCKER_COMPOSE
	${DOCKER_COMPOSE} exec -u root:root proxy.nginx sh -c '/bin/sh'

shell-proxy.letsencrypt: guard-DOCKER_COMPOSE
	${DOCKER_COMPOSE} exec -u root:root proxy.letsencrypt sh -c '/bin/sh'


## Tests
#########

# test-all: test-phpunit test-sonarqube

# test-sonarqube: guard-SONAR_HOST_URL guard-SONAR_LOGIN guard-INFRA_SRC_PSH guard-INFRA_DOCKER_PROXY
# 	docker run --rm \
# 	-e SONAR_HOST_URL=${SONAR_HOST_URL} \
# 	-e SONAR_LOGIN=${SONAR_LOGIN} \
# 	-v "${INFRA_SRC_PSH}:/usr/src" \
# 	${INFRA_DOCKER_PROXY}/sonarsource/sonar-scanner-cli \
# 	-Dsonar.projectKey=prestashop -Dsonar.scm.disabled=true -Dsonar.exclusions=vendor/**,var/** \
# 	-Dsonar.php.coverage.reportPaths=var/logs/coverage-report.xml -Dsonar.php.tests.reportPath=var/logs/tests-report.xml

# For phpunit command line options : https://phpunit.readthedocs.io/fr/latest/textui.html
# TODO : take a look at ``--process-isolation`` arguments
# test-phpunit: guard-EXEC_PSH_APP
# 	${EXEC_PSH_APP} 'php vendor/phpunit/phpunit/phpunit --coverage-clover var/logs/coverage-report.xml --log-junit var/logs/tests-report.xml tests'
# 	# ${EXEC_PSH_CLI} 'php vendor/phpunit/phpunit/phpunit --debug --verbose tests'

## Docker
##########

#  TODO : review docker build directory (depends on environments ?)
# docker-build-dev: guard-DOCKER_PSH_IMG guard-INFRA_DOCKER_PATH
# 	- docker image rm ${DOCKER_PSH_IMG}
# 	docker build \
# 		--build-arg working_dir=/var/www/html \
# 		-t ${DOCKER_PSH_IMG} -f ${INFRA_DOCKER_PATH}/build/Dockerfile.prestashop.7.4.dev ${INFRA_DOCKER_PATH}/build


# docker-login-dev: guard-DOCKER_REGISTRY_TOKEN guard-DOCKER_REGISTRY_USER guard-DOCKER_REGISTRY_BASE_PATH
# 	@echo "Docker login (command not logged for security purpose)"
# 	@echo "${DOCKER_REGISTRY_TOKEN}" | docker login -u ${DOCKER_REGISTRY_USER} --password-stdin ${DOCKER_REGISTRY_BASE_PATH}

# docker-push-dev: guard-DOCKER_PSH_IMG
# 	make docker-login-dev
# 	docker push ${DOCKER_PSH_IMG}

# docker-publish-dev: docker-build-dev docker-push-dev


## Services admin
##################

# TODO separate services
# services-reload-all: guard-EXEC_PSH_APP
# 	${EXEC_PSH_APP} 'nginx -s reload'

services-init-all: psh-init

services-config-all: proxy-config

# # TODO
# services-backup-all:
# 	echo "todo"

# # TODO
# services-restore-all:
# 	echo "todo"


## Proxy service admin
#######################

proxy-config:
	@sh -c '${INFRA_SCRIPT_PATH}/proxy_configure.sh ${INFRA_ENV_PATH}/proxy/etc/nginx/conf.d ${PROXY_BASE_HOSTNAME_LIST}'


## Prestashop service admin
############################

# TODO : deep clean of directory structure (cache and logs)

# Please notice that composer `--prefer-install=source` option is made for local development (keep .git in dependencies)
# Todo : make `--prefer-install=source` optional for "development" environments
psh-init: guard-EXEC_PSH_APP guard-EXEC_PSH_CLI_NPM
	${EXEC_PSH_APP} 'composer install' 
	${EXEC_PSH_APP} 'touch .htaccess'
	${EXEC_PSH_CLI_NPM} 'make assets'
#	 ${EXEC_PSH_APP} 'php bin/console ...'


# TODO : how to clean / manage ${INFRA_SRC_PSH}/cache ? Not considered : admin-dev/autoupgrade app/config app/Resources/translations config img mails override
# TODO : problem to fix with img
# TODO : add admin-dev/export admin-dev/import directories
# psh-clean-artefacts: guard-INFRA_SRC_PSH
# 	@echo "=== Remove install/dev artefacts"
# 	rm -rf ${INFRA_SRC_PSH}/themes/node_modules ${INFRA_SRC_PSH}/themes/core.js ${INFRA_SRC_PSH}/themes/core.js.map ${INFRA_SRC_PSH}/themes/core.js.LICENSE.txt
# 	cd ${INFRA_SRC_PSH}; \
# 		rm -rf app/logs log; mkdir -p app/logs log; \
# 		rm .htaccess; \
# 		rm var/bootstrap.php.cache; \
# 		rm app/config/parameters.php app/config/parameters.yml; \
# 		rm -rf config/settings.inc.php config/themes/classic; \
# 		rm -rf themes/classic/assets/cache; \
# 		find app/Resources/translations -maxdepth 1 -mindepth 1 -type d ! -name 'default' -or -type f ! -name '.gitkeep' | xargs -I {} sh -c "rm -rf {}"; \
# 		find download 	   -maxdepth 1 -mindepth 1 -type d -or -type f ! -name '.htaccess' ! -name 'index.php' | xargs -I {} sh -c "rm -rf {}"; \
# 		find config/themes -maxdepth 1 -mindepth 1 -type d -or -type f ! -name '.gitkeep'					   | xargs -I {} sh -c "rm -rf {}"; \
# 		find img/c 	   	   -maxdepth 1 -mindepth 1 -type d -or -type f ! -name 'index.php' 					   | xargs -I {} sh -c "rm -rf {}"; \
# 		find img/e 	   	   -maxdepth 1 -mindepth 1 -type d -or -type f ! -name 'index.php' 					   | xargs -I {} sh -c "rm -rf {}"; \
# 		find img/genders   -maxdepth 1 -mindepth 1 -type d -or -type f ! -name 'index.php' ! -name 'Unknown.jpg' | xargs -I {} sh -c "rm -rf {}"; \
# 		find img/l 	   	   -maxdepth 1 -mindepth 1 -type d -or -type f ! -name 'index.php' ! -name 'none.jpg'  | xargs -I {} sh -c "rm -rf {}"; \
# 		find img/m 	   	   -maxdepth 1 -mindepth 1 -type d -or -type f ! -name 'index.php' 					   | xargs -I {} sh -c "rm -rf {}"; \
# 		find img/p 	   	   -maxdepth 1 -mindepth 1 -type d -or -type f ! -name 'index.php' 					   | xargs -I {} sh -c "rm -rf {}"; \
# 		find img/os 	   -maxdepth 1 -mindepth 1 -type d -or -type f ! -name 'index.php' 					   | xargs -I {} sh -c "rm -rf {}"; \
# 		find img/st 	   -maxdepth 1 -mindepth 1 -type d -or -type f ! -name 'index.php' 					   | xargs -I {} sh -c "rm -rf {}"; \
# 		find img/su 	   -maxdepth 1 -mindepth 1 -type d -or -type f ! -name 'index.php' 					   | xargs -I {} sh -c "rm -rf {}"; \
# 		find img/tmp 	   -maxdepth 1 -mindepth 1 -type d -or -type f ! -name 'index.php' 					   | xargs -I {} sh -c "rm -rf {}"; \
# 		find mails		   -maxdepth 1 -mindepth 1 -type d ! -name '_partials' ! -name 'themes' -or -type f ! -name '.htaccess' ! -name 'index.php' | xargs -I {} sh -c "rm -rf {}"; \
# 		find modules 	   -maxdepth 1 -mindepth 1 -type d -or -type f ! -name '.htaccess' ! -name 'index.php' | xargs -I {} sh -c "rm -rf {}"; \
# 		find themes  	   -maxdepth 1 -mindepth 1 -type d -name 'hummingbird'								   | xargs -I {} sh -c "rm -rf {}"; \
# 		find translations  -maxdepth 1 -mindepth 1 -type d ! -name 'cldr' ! -name 'export' ! -name 'default' -or -type f ! -name 'index.php' | xargs -I {} sh -c "rm -rf {}"; \
# 		find upload 	   -maxdepth 1 -mindepth 1 -type d -or -type f ! -name '.htaccess' ! -name 'index.php' | xargs -I {} sh -c "rm -rf {}"; \
# 		find var/cache	   -maxdepth 1 -mindepth 1 -type d -or -type f ! -name '.gitkeep' 					   | xargs -I {} sh -c "rm -rf {}"; \
# 		find var/logs 	   -maxdepth 1 -mindepth 1 -type d -or -type f ! -name '.gitkeep' 					   | xargs -I {} sh -c "rm -rf {}"; \
# 		find var/sessions  -maxdepth 1 -mindepth 1 -type d -or -type f ! -name '.gitkeep' 					   | xargs -I {} sh -c "rm -rf {}"; \
# 		find vendor 	   -maxdepth 1 -mindepth 1 -type d -or -type f ! -name '.htaccess'					   | xargs -I {} sh -c "rm -rf {}"

# TODO : shouldn't we move this cache to env/data ?
psh-clean-infra-cache: guard-INFRA_DOCKER_PATH
	@echo "=== Remove npm and composer caches" 
	find ${INFRA_CACHE_PATH}/npm      -maxdepth 1 -mindepth 1 -type d -or -type f ! -name '.gitignore' | xargs -I {} sh -c "rm -rf {}"
	find ${INFRA_CACHE_PATH}/composer -maxdepth 1 -mindepth 1 -type d -or -type f ! -name '.gitignore' | xargs -I {} sh -c "rm -rf {}"


# Specific Prestashop development and test commands
####################################################

# TODO : add environment variables to customize and ensure consistency (name / email / password).
# TODO : check --db_create=1` usage
# Please notice shop is installed from first hostname off $PROXY_BASE_HOSTNAME_LIST
psh-dev-install-shop: guard-EXEC_PSH_APP
	${EXEC_PSH_APP} 'php install-dev/index_cli.php \
		--language=en \
		--country=fr \
		--domain=$(shell echo "$(PROXY_BASE_HOSTNAME_LIST)" | head -n1 | cut -d "," -f1) \
		--db_server=psh.db \
		--db_user=prestashop_admin \
		--db_password=prestashop_admin \
		--db_name=prestashop \
		--name=MeKeyShop \
		--email=mekeycool@prestashop.com \
		--password=adminadmin \
		--db_create=1'

# psh-admin-fix-rights:
# 	 ${EXEC_PSH_APP} 'chmod -R 777 admin-dev/autoupgrade admin-dev/export admin-dev/import app/config app/logs app/Resources/translations cache config download img log mails modules override themes translations upload var'
#	 ${EXEC_PSH_APP} 'mkdir -p admin-dev/autoupgrade app/config app/logs app/Resources/translations cache config download img log mails modules override themes translations upload var'

psh-dev-env-reset: env-reset infra-init infra-run psh-dev-install-shop

# TODO : remove modules, cache, artefacts, ... ?
psh-dev-reinstall: 
	${EXEC_PSH_APP} 'composer install'
	make psh-dev-install-shop

psh-dev-reinstall-with-assets: psh-init psh-dev-install-shop

# TODO : Should we run 'composer reinstall --prefer-install=source "prestashop/*"' instead ?
psh-dev-reinstall-with-sources: guard-EXEC_PSH_APP
	${EXEC_PSH_APP} 'composer reinstall --prefer-install=source "prestashop/*"'
	make psh-dev-install-shop

psh-test-all: psh-test-unit psh-test-integration psh-test-behaviour psh-test-stan

# NOTICE : If you want to list deprecation warnings, you may want to edit `SYMFONY_DEPRECATIONS_HELPER` value
# see https://symfony.com/doc/current/components/phpunit_bridge.html#configuration
psh-test-unit: guard-EXEC_PSH_APP
	${EXEC_PSH_APP} 'SYMFONY_DEPRECATIONS_HELPER=weak composer unit-test'
# 	${EXEC_PSH_APP} 'php -d date.timezone=UTC ./vendor/phpunit/phpunit/phpunit -c tests/Unit/phpunit.xml'
# 	${EXEC_PSH_APP} 'php -d date.timezone=UTC ./vendor/phpunit/phpunit/phpunit -c tests/Unit/phpunit.xml tests/Unit/Core/Module/ModuleRepositoryTest.php'

psh-test-integration: guard-EXEC_PSH_APP
	${EXEC_PSH_APP} 'composer integration-tests'	
#	${EXEC_PSH_APP} 'composer create-test-db'
#	${EXEC_PSH_APP} 'php -d date.timezone=UTC -d memory_limit=-1 ./vendor/phpunit/phpunit/phpunit -c tests/Integration/phpunit.xml tests/Integration/PrestaShopBundle/Controller/Sell/Customer/Address/AddressControllerTest.php'
# 	${EXEC_PSH_APP} 'composer -vvv integration-tests'

psh-test-behaviour: guard-EXEC_PSH_APP
	${EXEC_PSH_APP} 'composer integration-behaviour-tests'	

# https://phpstan.org/user-guide/command-line-usage
psh-test-stan: guard-EXEC_PSH_APP
	${EXEC_PSH_APP} 'php vendor/bin/phpstan analyse --memory-limit 2G -v -c phpstan.neon.dist'

# TODO add psh-test-sanity
# HEADLESS=false URL_FO=https://prestashop.php73.local/ DB_NAME=prestashop DB_PASSWD=root npm run sanity-travis

# Todo : find why does this command break the install
# psh-clean-cache: guard-EXEC_PSH_APP
# 	${EXEC_PSH_APP} 'php bin/console cache:clear'

psh-dev-watch-admin-dev: guard-EXEC_PSH_CLI_NPM
	${EXEC_PSH_CLI_NPM} 'cd admin-dev/themes/new-theme; npm run watch'
	# ${EXEC_PSH_CLI_NPM} 'cd admin-dev/themes/default; npm run watch'

psh-dev-watch-classic: guard-EXEC_PSH_CLI_NPM
	${EXEC_PSH_CLI_NPM} 'cd themes/classic/_dev; npm run watch'

psh-dev-build-front: guard-EXEC_PSH_CLI_NPM
	${EXEC_PSH_CLI_NPM} 'make assets'


psh-dev-apply-guidelines: guard-EXEC_PSH_APP guard-EXEC_PSH_CLI_NPM
	${EXEC_PSH_APP} 'php ./vendor/bin/php-cs-fixer fix'
	${EXEC_PSH_CLI_NPM} 'cd ./admin-dev/themes/new-theme && npm run lint-fix && npm run scss-fix'
# 	${EXEC_PSH_CLI_NPM} 'cd ./admin-dev/themes/new-theme && npm install'

psh-dev-check-commit: psh-test-unit psh-test-integration psh-dev-check-style

psh-dev-check-style: psh-dev-apply-guidelines psh-test-stan

# Todo : fix headers
# vendor/bin/header-stamp prestashop:licenses:update --license=/Users/mFerment/www/prestashop/blockreassurance/vendor/prestashop/header-stamp/assets/afl.txt

# Todo : create scripts with dev friendly module install interface
psh-dev-install-fop-console: guard-EXEC_PSH_APP guard-INFRA_SRC_PSH
	-${EXEC_PSH_APP} 'php bin/console pr:mo uninstall fop_console'
	-cd ${INFRA_SRC_PSH}/modules; rm -rf fop_console
	-cd ${INFRA_SRC_PSH}/modules; git clone git@github.com:friends-of-presta/fop_console.git
	${EXEC_PSH_APP} 'cd modules/fop_console; composer install'
	${EXEC_PSH_APP} 'php bin/console pr:mo install fop_console'
	${EXEC_PSH_APP} 'php bin/console -vvv fop:about:version'
	
psh-dev-fop-console-apply-guidelines: guard-EXEC_PSH_APP
	${EXEC_PSH_APP} 'cd modules/fop_console; php vendor/bin/php-cs-fixer --config=.php_cs-fixer.dist.php --path-mode=intersection --verbose fix src/Commands/Environment/EnvironmentGetParameters.php'


# https://github.com/PrestaShop/hummingbird
# Todo :
# 	- enhance hummingbird / theme install documentation 
# 	- Add some environment variable for http scheme (http/https) => problem with Prestashop management concurrency
#  	- How to manage multishop ?
psh-dev-install-hummingbird: guard-EXEC_PSH_CLI_NPM guard-INFRA_SRC_PSH
	-cd ${INFRA_SRC_PSH}/themes; rm -rf hummingbird
	-cd ${INFRA_SRC_PSH}/themes; git clone git@github.com:Prestashop/hummingbird.git
	@echo "generating .env"
	@cd ${INFRA_SRC_PSH}/themes/hummingbird/webpack; \
		rm -f ./.env; \
		echo "PORT=3505" >> .env; \
		echo "SERVER_ADDRESS=$(shell echo "$(PROXY_BASE_HOSTNAME_LIST)" | head -n1 | cut -d "," -f1)" >> .env; \
		echo "SITE_URL=https://$(shell echo "$(PROXY_BASE_HOSTNAME_LIST)" | head -n1 | cut -d "," -f1)" >> .env; \
		echo "PUBLIC_PATH=/themes/hummingbird/assets/" >> .env;
	${EXEC_PSH_CLI_NPM} 'cd themes/hummingbird; npm i'
	${EXEC_PSH_CLI_NPM} 'cd themes/hummingbird; npm run build'

# TODO : find a generic way to "npm run watch" a theme according dynamic choice.
#  		 https://stackoverflow.com/questions/68441570/makefile-targets-autocomplete-when-using-wild-card-targets
psh-dev-watch-hummingbird: guard-EXEC_PSH_CLI_NPM
	${EXEC_PSH_CLI_NPM} 'cd themes/hummingbird; npm run watch'

psh-dev-check-commit-hummigbird:
	${EXEC_PSH_CLI_NPM} 'cd themes/hummingbird; npm run scss-fix'
	${EXEC_PSH_CLI_NPM} 'cd themes/hummingbird; npm run lint-fix'
	${EXEC_PSH_CLI_NPM} 'cd themes/hummingbird; npm run test'

psh-dev-check-commit-classic:
	${EXEC_PSH_CLI_NPM} 'cd themes/classic/_dev; npm run lint-fix; npm run scss-fix'
