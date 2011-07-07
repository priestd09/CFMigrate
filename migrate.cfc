<cfcomponent output="true">

	<cfproperty name="datasource" type="string" />
	<cfproperty name="dbUsername" type="string" />
	<cfproperty name="dbPassword" type="string" />
	<cfproperty name="verbose" type="boolean" />

	<cffunction name="init" access="public" output="false" returntype="any" hint="The public constructor">
		<cfargument name="datasource" type="string" required="true" hint="The datasource to operate on" />
		<cfargument name="dbUsername" type="string" hint="The DB username, if required" default="" />
		<cfargument name="dbPassword" type="string" hint="The DB password, if required" default="" />
		<cfargument name="verbose" type="boolean" hint="If true, output progress information" default="false" />
		<cfargument name="directoryName" type="string" required="false" hint="The directory migrations are run from" />
		<cfargument name="directoryPath" type="string" required="false" hint="The path to the migrations directory in dot form, used to instantiate the migrations.  Required if directoryName is specific. Example: path.to.migrations" />

		<cfset variables.datasource = arguments.datasource />
		<cfset variables.dbUsername = arguments.dbUsername />
		<cfset variables.dbPassword = arguments.dbPassword />
		<cfset variables.verbose = arguments.verbose />
		<cfif structKeyExists(arguments, "directoryName")>
			<cfset variables.directory_name = arguments.directoryName />
			<cfset variables.directory_path = arguments.directoryPath />
		<cfelse>
			<cfset variables.directory_name = getDirectoryFromPath(getCurrentTemplatePath()) />
			<cfif structKeyExists(arguments, "directoryPath")>
				<cfset variables.directory_path = arguments.directoryPath />
			<cfelse>
				<!--- Assume we're running out of a /migrations directory --->
				<cfset variables.directory_path = "migrations." />
			</cfif>
		</cfif>
		<cfif right(variables.directory_path, 1) NEQ ".">
			<cfset variables.directory_path &= "." />
		</cfif>
		<cfset variables.sample_path = getDirectoryFromPath(getCurrentTemplatePath()) & "sample_migration.cfc" />

		<cfreturn this />
	</cffunction>


	<cffunction name="run_migrations" displayname="run_migrations" access="public" output="true" returntype="boolean">
		 <cfargument name="migrate_to_version" displayName="migration_name" type="String" required="false" />
			
			<cfset var migrations_list = "">
			<cfset var migration_number = "">
			<cfset var st = "">
			<cfset var REmigration_version = "\d{14}">
			
			<cftry>
				<cfquery name="get_migrations" datasource="#variables.datasource#" username="#variables.dbUsername#" password="#variables.dbPassword#">
					Select migration_number from migrations
				</cfquery>
				<cfset migrations_list = ValueList(get_migrations.migration_number)>
				<cfcatch type="database">
					<cfif variables.verbose>
						The migrations could not run, there was an error trying to access the migrations table. You must run migrations setup to create the migrations table prior to running your first migration.
						<cfset migrations_list = "">
					<cfelse>
						<cfthrow type="cfmigrate.setup" message="The migrations could not run, there was an error trying to access the migrations table. You must run migrations setup to create the migrations table prior to running your first migration." />
					</cfif>
					<cfabort>
				</cfcatch>
			</cftry>
	
			<!--- get the list of migration cfc's from the migrations folder --->
			<cfdirectory action="LIST" 
				directory="#variables.directory_name#" 
				name="migration_files" 
				filter="*_mg.cfc"> <!--- valid migration files must end in _mg --->
				
			<!--- If a migration version was provided to revert to, check that it is a valid version 
				that was previously run --->
			<cfif isdefined("ARGUMENTS.migrate_to_version") and ListFind(migrations_list, migrate_to_version) eq 0>
				<cfif variables.verbose>
					<cfoutput>
					ERROR: A migration version to revert to was provided, but a previously run migration matching this version number could not be found. You must supply a version that was previously run. 
					</cfoutput>
				<cfelse>
					<cfthrow type="cfmigrate.invalid" message="A migration version to revert to was provided, but a previously run migration matching this version number could not be found. You must supply a version that was previously run." />
				</cfif>
				<cfabort>
			</cfif>
				
			<cfif isdefined("ARGUMENTS.migrate_to_version")>
				<!--- The user want to run migrations to a certain migration number. If a previous migration
				has been run, revert it. Do not run migrations that have not been run --->
				<cfquery name="sorted_migrations" dbtype="query">
						select * from migration_files
						order by name DESC
				</cfquery>
				<cfloop query="sorted_migrations">
					<cfset st = REFind(REmigration_version,sorted_migrations.name,1,"TRUE")>
					<cfset migration_number = Mid(sorted_migrations.name,st.pos[1],st.len[1])>
					<!--- strip the .cfc from the file name --->
					<cfset migration_name = left(sorted_migrations.name, len(sorted_migrations.name) - 4)>
					
					<!--- If the migration is a later version than the version to revert to, 
					and the migration was previously run, revert the migration --->
					<cfif (migration_number gt ARGUMENTS.migrate_to_version) and ListFind(migrations_list, migration_number) neq 0 >
						<cfif variables.verbose>
							<cfoutput>
							Reverting #migration_files.name# migration
							</cfoutput>
						</cfif>
						<!--- wrap the migration in a transaction so if it fails --->
						<cftransaction>
							<cftry>
								<cfset migration_cfc = createObject("component", "#variables.directory_path##migration_name#").init(variables.datasource, variables.dbUsername, variables.dbPassword)>
								<cfset migration_cfc.migrate_down() >
								<cfquery name="store_migration" datasource="#variables.datasource#" username="#variables.dbUsername#" password="#variables.dbPassword#">
									Delete from migrations where migration_number = '#migration_number#'
								</cfquery>
								<cfcatch type="any">
									<cftransaction action="rollback" />
									<cfif variables.verbose>
										<cfoutput>
										<p>There was an error in the migration, the changes in this migration 
										have been rolled back and no other migrations will be run. </p>
										<p>#cfcatch.message#</p>
										<cfif cfcatch.type EQ "database">
											<p>#cfcatch.queryError#</p>
											<p>#cfcatch.sql#</p>
										</cfif>
										</cfoutput>
									<cfelse>
										<cfrethrow />
									</cfif>
									<cfbreak>
								</cfcatch>
							</cftry>
						</cftransaction>
					</cfif> 
	
				</cfloop>
			<cfelse>
			<!--- No migration version was passed in, so run all of the migrations that have not yet been run --->
			
				<cfquery name="sorted_migrations" dbtype="query">
						select * from migration_files
						order by name ASC
				</cfquery>
				<cfloop query="sorted_migrations">
					<cfset st = REFind(REmigration_version,sorted_migrations.name,1,"TRUE")>
					<cfset migration_number = Mid(sorted_migrations.name,st.pos[1],st.len[1])>
					<!--- strip the .cfc from the file name --->
					<cfset migration_name = left(sorted_migrations.name, len(sorted_migrations.name) - 4)>
					
					<!--- If the migration has not been run, run it --->
					<cfif ListFind(migrations_list, migration_number) eq 0 >
						<cfif variables.verbose>
							<cfoutput>
							Running #migration_files.name# migration
							</cfoutput>
						</cfif>
						<!--- wrap the migration in a transaction so if it fails --->
						<cftransaction>
							<cftry>
								<cfset migration_cfc = createObject("component", "#variables.directory_path##migration_name#").init(variables.datasource, variables.dbUsername, variables.dbPassword)>
								<cfset migration_cfc.migrate_up() >
								<cfquery name="store_migration" datasource="#variables.datasource#" username="#variables.dbUsername#" password="#variables.dbPassword#">
									Insert into migrations (migration_number, migration_run_at) values
										('#migration_number#', getdate())
								</cfquery>
								<cfcatch type="any">
									<cftransaction action="rollback" />
									<cfif variables.verbose>
										<cfoutput>
											<p>There was an error in the migration, the changes in this migration 
											have been rolled back and no other migrations will be run. </p>
											<p>#cfcatch.message#</p>
											<cfif cfcatch.type EQ "database">
												<p>#cfcatch.queryError#</p>
												<p>#cfcatch.sql#</p>
											</cfif>
										</cfoutput>
										<cfbreak>
									<cfelse>
										<cfrethrow />
									</cfif>
								</cfcatch>
							</cftry>
						</cftransaction>
					</cfif> 
	
				</cfloop>
				
			</cfif>
							
		<cfreturn true />
	</cffunction>

	<cffunction name="create_migration" displayname="create_migration" access="public" output="true" returntype="string">
		<cfargument name="migration_name" displayName="migration_name" type="String" required="true" />
		
		<cfset var fileName = variables.directory_name & "/" & dateFormat(now(), "yyyymmdd") & timeFormat(now(), "hhmmss") & "_" & arguments.migration_name & "_mg.cfc" />
		<cffile action="read"
				file="#variables.sample_path#"
				variable="sample_file"	>
		<cffile action="write"
				file = "#fileName#"
				output = "#sample_file#">
		<cfif variables.verbose>
			<cfoutput>
				The migration file was created
			</cfoutput>
		</cfif>
		<cfreturn fileName />
	</cffunction>
	
	<cffunction name="setup_migrations" displayname="setup_migrations" access="public" output="true" returntype="boolean">
		
			<!---create the migrations table --->
			<cfquery name="create_migrations_table" datasource="#variables.datasource#" username="#variables.dbUsername#" password="#variables.dbPassword#">
				CREATE TABLE [dbo].[migrations](
					[migration_number] [varchar](14) NOT NULL,
					[migration_run_at] [datetime] NOT NULL
					) 
			</cfquery>
		
		<cfif variables.verbose>
			<cfoutput>
				The migration table was created
			</cfoutput>
		</cfif>

		<cfreturn true />
	</cffunction>

</cfcomponent>