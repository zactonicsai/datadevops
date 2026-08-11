To set a custom username and password in Apache NiFi 1.28 (single-user authentication, the default mode), use the built-in command.
Steps
	1	Stop NiFi (if it is running):
	◦	Linux/Unix: ./bin/nifi.sh stop
	◦	Windows: bin\nifi.cmd stop
	2	Set the credentials (run from the NiFi installation root directory):
	◦	Linux / macOS / Unix: ./bin/nifi.sh set-single-user-credentials  
	◦	
	◦	Windows: bin\nifi.cmd set-single-user-credentials  
	◦	
	3	Requirements:
	◦	Username: minimum 4 characters
	◦	Password: minimum 12 characters
	4	Example: ./bin/nifi.sh set-single-user-credentials admin MySecurePass123
	5	
	6	Start NiFi again:
	◦	Linux/Unix: ./bin/nifi.sh start
	◦	Windows: bin\nifi.cmd start
	7	Access the UI (usually https://localhost:8443/nifi) and log in with the username/password you just set.
Notes
	•	The command updates conf/login-identity-providers.xml (it hashes the password with bcrypt).
	•	By default NiFi generates a random UUID username + random password and logs them in logs/nifi-app.log (search for “Generated Username” / “Generated Password”).
	•	You must restart NiFi after changing the credentials.
	•	This is for the single-user provider only. For multiple users you need LDAP, Kerberos, OpenID Connect, or certificate-based auth.
This works the same way in NiFi 1.28 as in recent 1.x versions.
